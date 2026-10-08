// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import PocketCore
import UIKit

/// What the UI shows. Copied out under a lock; the UI reads it only while the app is active.
struct EngineSnapshot: Equatable {
    var link = LinkState.off
    var linkDetail: String?
    var deviceName: String?
    var info: DeviceInfo?
    var battery: UInt8?
    var charging = Charging.unknown
    var versionError: String?
    var lastPressAt: Date?
    var lastReply: String?
}

/// Coordinates the Passport link, voice notes and replies. All state lives on `queue`, which is
/// also the CoreBluetooth delegate queue, so a BLE notification costs no thread hop.
///
/// Background rules (measured on an iPhone XS Max: iOS killed an app at 93 % CPU over 52 s for
/// re-rendering SwiftUI on every frame): per audio frame only decode + append; logging and
/// network work happen once per press; nothing here touches UIKit or SwiftUI state.
final class PocketEngine: @unchecked Sendable {
    static let shared = PocketEngine()

    let queue = DispatchQueue(label: "pocket.engine", qos: .userInitiated)
    let link: PassportLink
    private let display = DisplaySocket()
    private var tuning = PocketTuning.load()
    private var settings = ChannelSettings.load()

    private var assembler = PressAssembler()
    private var tracker = ReplyTracker()
    private var savedReplyID: UInt32 = 0
    private var refused = false

    // Per-press measurements.
    private var pressCPU0 = 0.0
    private var pressWall0 = 0.0

    // Reply wait (docs/ble-protocol.md §9). No time limit: it ends on the answer, on
    // `turn idle`, or when the display socket cannot be restored.
    private var awaiting = false
    private var waitStarted = 0.0
    private var displayBusy = false
    /// Callers of a running `fetchMissed`.
    private var fetchWaiters: [((Bool) -> Void)?] = []

    private var serverReachable: Bool?
    private let pressTask = BackgroundTask(name: "pocket.press")
    private let replyTask = BackgroundTask(name: "pocket.reply")

    private let snapLock = NSLock()
    private var snap = EngineSnapshot()

    private init() {
        link = PassportLink(queue: queue)
        let defaults = UserDefaults.standard
        if let d = defaults.data(forKey: Keys.replyMemory),
           let m = try? JSONDecoder().decode(ReplyTracker.Memory.self, from: d) {
            tracker.memory = m
            savedReplyID = m.lastReplyID
        }
        link.onMessage = { [unowned self] in handle($0) }
        link.onReady = { [unowned self] in linkReady() }
        link.onDisconnected = { [unowned self] in linkLost() }
        link.onState = { [unowned self] s, d in
            update { $0.link = s; $0.linkDetail = d; $0.deviceName = self.link.peripheralName }
        }
        display.onFrame = { [unowned self] f in queue.async { self.displayFrame(f) } }
        display.onClosed = { [unowned self] why in queue.async { self.displayClosed(why) } }
    }

    /// Called from application(_:didFinishLaunchingWithOptions:).
    func start() {
        Tailnet.shared.apply(settings)
        Tailnet.shared.start()
        link.start()
    }

    func snapshot() -> EngineSnapshot {
        snapLock.lock(); defer { snapLock.unlock() }
        return snap
    }

    private func update(_ f: (inout EngineSnapshot) -> Void) {
        snapLock.lock(); f(&snap); snapLock.unlock()
    }

    func settingsChanged() {
        queue.async { [self] in
            settings = ChannelSettings.load()
            tuning = PocketTuning.load()
            Tailnet.shared.apply(settings)
            display.close()
            ensureDisplay("settings")
        }
    }

    func appBecameActive() {
        queue.async { [self] in
            Tailnet.shared.closeIdle()
            ensureDisplay("foreground")
            link.retryStaleBond()
        }
    }

    /// A request failed for lack of a connection: check the display socket now.
    func connectionLost() {
        queue.async { [self] in ensureDisplay("request_failed") }
    }

    /// Pause between display-socket attempts while the app is visible: the web edge's 1 s
    /// (`transport.js`). Each attempt is itself bounded by `connectTimeout`.
    static let redialDelay: TimeInterval = 1

    // MARK: device messages

    private func handle(_ m: DeviceMessage) {
        switch m {
        case .audio:
            // Hot path: one append.
            guard !refused else { return }
            for e in assembler.handle(m) { pressEvent(e) }
        case .pressStart, .pressEnd:
            guard !refused else { return }
            for e in assembler.handle(m) { pressEvent(e) }
        case .info(let i):
            refused = !i.compatible
            let err = refused ? "Passport protocol \(i.protoMajor).\(i.protoMinor), app speaks \(PocketConstants.protoMajor).x" : nil
            AppLog.shared.log("device_info", ["proto": "\(i.protoMajor).\(i.protoMinor)", "fw": i.firmware,
                                              "battery": i.battery, "charging": i.charging.rawValue, "preroll": i.preroll,
                                              "refused": refused])
            update { $0.info = i; $0.battery = i.battery; $0.charging = i.charging; $0.versionError = err }
            // ble-protocol §8: tell the device so it shows the mismatch too.
            if refused { sendAppState(.protocolMismatch) }
        case .status(let b, let c):
            update { $0.battery = b; $0.charging = c }
        case .keepalive(let id):
            // The device waits for a reply. After a relaunch the app may have lost that state:
            // adopt the wait so REPLY_DONE is still sent.
            if !awaiting {
                AppLog.shared.log("keepalive_adopt", ["press": id, "app": AppPhase.value])
                startReplyWait(uttID: nil)
            } else {
                ensureDisplay("keepalive")
            }
        }
    }

    private func pressEvent(_ e: PressAssembler.Event) {
        switch e {
        case .started(let id, let implicit):
            pressTask.begin()
            // Decision Q12: the phone's ambient mic must not hear the same speech.
            AmbientController.shared.pressBegan()
            pressCPU0 = CPUClock.processSeconds()
            pressWall0 = CPUClock.uptime()
            AppLog.shared.log("press_start", ["press": id, "implicit": implicit, "app": AppPhase.value])
            // ble-protocol §9: a new press ends the device's wait for the previous reply; drop
            // ours too. A late answer still goes out as REPLY.
            if awaiting { endReplyWait("new_press") }
            // Warm the tailnet while the user speaks: the wake cost overlaps the press.
            DispatchQueue.global(qos: .utility).async { [tuning] in
                Tailnet.shared.closeIdle()
                try? Tailnet.shared.up(timeout: tuning.connectTimeout)
            }
        case .completed(let c):
            AmbientController.shared.pressEnded()
            finishPress(c)
        }
    }

    private func finishPress(_ c: CompletedPress) {
        let endWall = CPUClock.uptime(), endCPU = CPUClock.processSeconds()
        let pressWall = max(endWall - pressWall0, 0.001)
        let pressCPUPct = (endCPU - pressCPU0) / pressWall * 100
        let note = VoiceNote(source: .passport, packets: c.packets)
        let room = settings.room
        let uploader = VoiceUploader(transport: TsnetTransport(tuning: tuning), tuning: tuning)
        pressTask.begin()
        Task.detached { [self] in
            let report = settings.isComplete
                ? await uploader.upload(note, room: room)
                : VoiceUploadReport(outcome: .notConnected("no channel configured"), attempts: 0, trail: [], elapsed: 0)
            queue.async { [self] in
                let doneWall = CPUClock.uptime(), doneCPU = CPUClock.processSeconds()
                let outcome = report.outcome
                link.send(.result(pressID: c.pressID, code: outcome.resultCode, text: outcome.text))
                // One line per press, with its CPU share (background CPU budget).
                AppLog.shared.log("press", [
                    "press": c.pressID, "voice_id": note.id.uuidString.lowercased(), "app": AppPhase.value,
                    "packets": c.stats.packets, "declared": c.stats.declaredCount ?? -1, "gaps": c.stats.gaps,
                    "dups": c.stats.duplicates, "bytes": c.stats.bytes, "end": c.stats.end.rawValue,
                    "implicit_start": c.stats.implicitStart, "audio_ms": note.durationMs,
                    "press_wall_s": pressWall, "press_cpu_pct": pressCPUPct,
                    "upload_ms": Int(report.elapsed * 1000), "attempts": report.attempts, "trail": report.trail,
                    "upload_cpu_pct": (doneCPU - endCPU) / max(doneWall - endWall, 0.001) * 100,
                    "code": outcome.resultCode.rawValue, "text_len": outcome.text.count,
                ])
                setReachable(!(outcome.resultCode == .notConnectedToServer))
                update { $0.lastPressAt = Date() }
                if outcome.resultCode == .transcribed {
                    startReplyWait(uttID: outcome.uttID)
                    ConversationStore.shared.passportNote(uttID: outcome.uttID, durationMs: note.durationMs)
                }
                pressTask.end()
            }
        }
    }

    private func linkReady() {
        AppLog.shared.log("device_ready", ["app": AppPhase.value])
        resendAppState()
        // The newest answer the device has not been handed (it came while the link was down):
        // send it now. One it already got is not repeated, because the Passport alerts on
        // every REPLY.
        if let a = tracker.answerForNewLink {
            deliver([.reply(replyID: a.replyID, final: true, text: a.text), .replyDone(replyID: a.replyID)],
                    source: "link_ready")
        }
        probeServer()
        // A BLE wake: answers that came while the app was suspended exist only in the room log.
        fetchMissed("link_ready")
    }

    /// APP_STATE always carries the app's UI language (ble-protocol §7 item 9).
    private func sendAppState(_ state: AppState) {
        link.send(.appState(state, language: Self.uiLanguage))
    }

    /// The current APP_STATE again: at link ready and when the UI language changes. Nothing
    /// before the first reachability result; that result sends it.
    private func resendAppState() {
        if refused {
            sendAppState(.protocolMismatch)
        } else if let r = serverReachable {
            sendAppState(r ? .ok : .serverUnreachable)
        }
    }

    /// The language the app's UI resolved to (iOS relaunches the app when it changes).
    static var uiLanguage: UILanguage { UILanguage(localization: Bundle.main.preferredLocalizations.first) }

    private func linkLost() {
        for e in assembler.linkLost() { pressEvent(e) }
    }

    private func setReachable(_ ok: Bool) {
        guard serverReachable != ok else { return }
        serverReachable = ok
        if !refused { sendAppState(ok ? .ok : .serverUnreachable) }
    }

    /// Checks the channel once (link up, settings change) so APP_STATE is true before a press.
    private func probeServer() {
        guard settings.isComplete else { return setReachable(false) }
        let t = TsnetTransport(tuning: tuning)
        Task.detached { [self] in
            let ok: Bool
            do {
                let (status, _) = try await t.send(method: "GET", path: "/healthz", headers: [:], body: Data(),
                                                   timeout: tuning.connectTimeout)
                ok = status == 200
            } catch {
                ok = false
            }
            queue.async { self.setReachable(ok) }
        }
    }

    // MARK: replies

    /// `uttID` from the voice-note response marks when the note was sent: the first answer after
    /// it is the reply, whatever `utt_id` the answer names (`ReplyTracker`); nil means the next
    /// answer is the reply.
    private func startReplyWait(uttID: String?) {
        let start = tracker.expect(uttID: uttID)
        AppLog.shared.log("reply_wait", ["utt_id": uttID ?? "", "app": AppPhase.value])
        awaiting = true
        waitStarted = CPUClock.uptime()
        replyTask.begin()
        deliver(start, source: "wait")
        ensureDisplay("reply_wait")
    }

    private func endReplyWait(_ why: String) {
        tracker.stopExpecting()
        awaiting = false
        AppLog.shared.log("reply_wait_end", ["why": why, "after_s": Int(CPUClock.uptime() - waitStarted), "app": AppPhase.value])
        replyTask.end()
    }

    private func deliver(_ msgs: [PhoneMessage], source: String) {
        var why = "answer"
        for m in msgs {
            let linked = link.send(m)
            switch m {
            case .reply(let id, true, let text):
                if linked { tracker.handedToLink(replyID: id) }
                AppLog.shared.log("reply", ["source": source, "id": id, "len": text.count, "awaiting": awaiting,
                                            "linked": linked, "app": AppPhase.value])
                update { $0.lastReply = text }
                saveReplyMemory()
            case .reply:
                // A partial may take a new id; the counter must not go back after a relaunch.
                if tracker.memory.lastReplyID != savedReplyID { saveReplyMemory() }
            case .work(let phase, _):
                AppLog.shared.log("work", ["phase": phase.rawValue, "source": source, "app": AppPhase.value])
            case .replyDone(PocketConstants.noReplyID):
                why = "idle"
            default:
                break
            }
        }
        if awaiting, !tracker.awaiting { endReplyWait(why) }
    }

    private func saveReplyMemory() {
        guard let d = try? JSONEncoder().encode(tracker.memory) else { return }
        UserDefaults.standard.set(d, forKey: Keys.replyMemory)
        savedReplyID = tracker.memory.lastReplyID
    }

    private func displayFrame(_ f: [String: Any]) {
        ConversationStore.shared.frame(f)
        deliver(tracker.handle(frame: f), source: "live")
    }

    /// Reads the room log once, without the display socket, and forwards an answer the device
    /// has not had (BLE wake, background refresh). `done` gets whether the log was
    /// read, on `queue`. A fetch already running absorbs this one.
    func fetchMissed(_ reason: String, done: ((Bool) -> Void)? = nil) {
        queue.async { [self] in
            guard settings.isComplete else { done?(false); return }
            fetchWaiters.append(done)
            guard fetchWaiters.count == 1 else { return }
            let s = settings, tuning = tuning
            let t0 = CPUClock.uptime()
            DispatchQueue.global(qos: .utility).async { [self] in
                let entries = Self.fetchLog(s, tuning)
                queue.async { [self] in
                    AppLog.shared.log("fetch_missed", ["reason": reason, "ok": entries != nil, "rows": entries?.count ?? 0,
                                                       "ms": Int((CPUClock.uptime() - t0) * 1000), "link": link.state.rawValue,
                                                       "app": AppPhase.value])
                    if let entries { deliver(tracker.catchUp(entries: entries), source: reason) }
                    let waiters = fetchWaiters
                    fetchWaiters = []
                    for w in waiters { w?(entries != nil) }
                }
            }
        }
    }

    /// The display socket matters while the screen is visible, while a Passport reply is pending,
    /// and while ambient runs (its answers land in the thread cache).
    private var wantDisplay: Bool { awaiting || AppPhase.isActive || AmbientController.shared.snapshot().isOn }

    private func displayClosed(_ why: String) {
        AppLog.shared.log("display_closed", ["reason": why, "app": AppPhase.value])
        if wantDisplay { ensureDisplay("reopen") }
    }

    /// Makes sure the display socket is live, then catches up from the room log.
    private func ensureDisplay(_ reason: String) {
        guard settings.isComplete, !displayBusy else { return }
        displayBusy = true
        let s = settings, tuning = tuning
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let t0 = CPUClock.uptime()
            var opened = false
            var failure: String?
            if !(display.isOpen && display.ping(timeout: tuning.pingTimeout)) {
                do {
                    try display.open(room: s, timeout: tuning.connectTimeout)
                    opened = true
                } catch {
                    failure = "\(error)"
                }
            }
            // Catch-up: an answer may have arrived while the socket was down.
            var entries: [[String: Any]] = []
            if failure == nil {
                if let e = Self.fetchLog(s, tuning) {
                    entries = e
                    if opened, reason == "reopen" { ConversationStore.shared.displayReopened() }
                } else {
                    failure = "state request failed"
                }
            }
            if failure != nil { ConversationStore.shared.connectFailed() }
            queue.async { [self] in
                displayBusy = false
                AppLog.shared.log("display", ["reason": reason, "opened": opened, "err": failure ?? "",
                                              "ms": Int((CPUClock.uptime() - t0) * 1000), "app": AppPhase.value])
                setReachable(failure == nil)
                if failure != nil, AppPhase.isActive || AmbientController.shared.snapshot().isOn {
                    queue.asyncAfter(deadline: .now() + Self.redialDelay) { [self] in ensureDisplay("retry") }
                }
                if failure != nil, awaiting {
                    // ble-protocol §9: the answer cannot arrive without the display socket.
                    // setReachable has told the device (APP_STATE 1); release it from its wait.
                    link.send(.replyDone(replyID: PocketConstants.noReplyID))
                    endReplyWait("display_lost")
                }
                deliver(tracker.catchUp(entries: entries), source: "catchup")
            }
        }
    }

}

extension PocketEngine {
    /// `GET /api/state`: the room's recent log (oldest first), or nil when the request failed.
    /// Also refreshes the conversation cache. Blocking; call off `queue`.
    fileprivate static func fetchLog(_ s: ChannelSettings, _ tuning: PocketTuning) -> [[String: Any]]? {
        guard let (status, body) = try? Tailnet.shared.request(method: "GET", path: "/api/state?room=\(s.roomQuery)",
                                                               timeout: tuning.connectTimeout,
                                                               upTimeout: tuning.connectTimeout),
              status == 200, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let st = RoomState.decode(body) { ConversationStore.shared.connected(st) }
        return obj["imlog"] as? [[String: Any]] ?? []
    }
}

/// One named UIApplication background task; begin/end are idempotent.
final class BackgroundTask: @unchecked Sendable {
    private let name: String
    private let lock = NSLock()
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) { self.name = name }

    func begin() {
        lock.lock(); defer { lock.unlock() }
        guard id == .invalid else { return }
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            AppLog.shared.log("bg_task_expired", ["name": self?.name ?? ""])
            self?.end()
        }
    }

    func end() {
        lock.lock()
        let old = id
        id = .invalid
        lock.unlock()
        if old != .invalid { UIApplication.shared.endBackgroundTask(old) }
    }
}
