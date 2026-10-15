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

/// Coordinates the Passport link, voice notes and replies, and keeps the room's `/live` connection
/// (held by `AmbientController`) open while it is wanted. All state lives on `queue`, which is
/// also the CoreBluetooth delegate queue, so a BLE notification costs no thread hop.
///
/// Every `/live` frame passes through here: rows go to the conversation store first (it holds the
/// cursor) and then to the reply tracker; lifecycle events settle Passport RESULTs.
///
/// Background rules (measured on an iPhone XS Max: iOS killed an app at 93 % CPU over 52 s for
/// re-rendering SwiftUI on every frame): per audio frame only decode + append; logging and
/// network work happen once per press; nothing here touches UIKit or SwiftUI state.
final class PocketEngine: @unchecked Sendable {
    static let shared = PocketEngine()

    let queue = DispatchQueue(label: "pocket.engine", qos: .userInitiated)
    let link: PassportLink
    private var live: LiveSocket { AmbientController.shared.live }
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
    // `turn idle`, or when the `/live` connection cannot be restored.
    private var awaiting = false
    private var waitStarted = 0.0
    private var liveBusy = false
    /// A check was asked for while one ran: run another when it ends, so a request made after
    /// the running check read its inputs is not lost.
    private var liveRecheck: String?
    /// The connection was opened with a cursor: rows before `ready` are its replay, and `ready`
    /// settles what the app still waits on.
    private var liveReplays = false
    /// Counts `/live` opens; a `ready` speaks for messages accepted before its connection opened.
    private var liveGeneration = 0
    /// The current connection's `ready` and the generation it belongs to.
    private var lastReady: (ready: LiveEvent.Ready, generation: Int)?
    /// Replayed rows not yet given to the store, until `ready` (one write for the batch).
    private var replayRows: [ImlogEntry]?
    /// Callers of a running `fetchMissed`.
    private var fetchWaiters: [((Bool) -> Void)?] = []

    /// A Passport press waiting for its RESULT, by message id (docs/ble-protocol.md §8).
    private struct PressResult {
        var pressID: UInt16
        var wait: VoiceResultWait
        var durationMs: Int
        /// The `/live` generation when the upload got its 202. Only a `ready` of a connection opened
        /// after it is a snapshot that includes the message.
        var acceptedGeneration: Int?
        var expiry: DispatchWorkItem
    }
    private var results: [String: PressResult] = [:]

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
            PocketSurface.changed()
        }
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
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                AmbientController.shared.closeLive()
                queue.async { self.ensureLiveOnQueue("settings") }
            }
        }
    }

    func appBecameActive() {
        queue.async { [self] in
            Tailnet.shared.closeIdle()
            ensureLiveOnQueue("foreground")
            link.retryStaleBond()
        }
    }

    /// The `audio` switch wanted for `/live` changed (setting, foreground): replace the connection
    /// while it is wanted; otherwise close it, so nothing plays in the background.
    func liveAudioChanged(_ reason: String) {
        queue.async { [self] in
            if wantLive { return ensureLiveOnQueue(reason) }
            DispatchQueue.global(qos: .userInitiated).async { AmbientController.shared.closeLive() }
        }
    }

    /// A request failed for lack of a connection: check the `/live` connection now.
    func connectionLost() {
        queue.async { [self] in ensureLiveOnQueue("request_failed") }
    }

    /// Makes sure the `/live` connection is open while it is wanted (ambient on and off).
    func ensureLive(_ reason: String) {
        queue.async { [self] in if wantLive { ensureLiveOnQueue(reason) } }
    }

    /// Pause between `/live` attempts while the app is visible or ambient runs: the web edge's
    /// 1 s (`transport.js`). Each attempt is itself bounded by `connectTimeout`.
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
                startReplyWait(messageID: nil)
            } else {
                ensureLiveOnQueue("keepalive")
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

    /// Uploads the press as a voice message. RESULT waits for the channel's `message cleaned` on
    /// `/live` (or a failure), all within `resultDeadline` from PRESS_END. The wait is registered
    /// under the message id before the upload, so an event that beats the 202 is not missed.
    private func finishPress(_ c: CompletedPress) {
        let endWall = CPUClock.uptime(), endCPU = CPUClock.processSeconds()
        let pressWall = max(endWall - pressWall0, 0.001)
        let pressCPUPct = (endCPU - pressCPU0) / pressWall * 100
        let note = VoiceNote(source: .passport, packets: c.packets)
        let id = VoiceUploader.messageID(for: note)
        let room = settings.room
        let uploader = VoiceUploader(transport: TsnetTransport(tuning: tuning), tuning: tuning)
        let fields: [String: Any] = [
            "press": c.pressID, "message_id": id, "packets": c.stats.packets, "declared": c.stats.declaredCount ?? -1,
            "gaps": c.stats.gaps, "dups": c.stats.duplicates, "bytes": c.stats.bytes, "end": c.stats.end.rawValue,
            "implicit_start": c.stats.implicitStart, "audio_ms": note.durationMs, "press_wall_s": pressWall,
            "press_cpu_pct": pressCPUPct,
        ]
        pressTask.begin()
        update { $0.lastPressAt = Date() }
        // A press with no audio is an empty note; nothing is sent.
        guard !note.packets.isEmpty else {
            link.send(.result(pressID: c.pressID, code: .empty, text: ""))
            AppLog.shared.log("press", fields.merging(["code": ResultCode.empty.rawValue]) { a, _ in a })
            pressTask.end()
            return
        }
        guard settings.isComplete else {
            link.send(.result(pressID: c.pressID, code: .notConnectedToServer, text: ""))
            setReachable(false)
            pressTask.end()
            return
        }
        let deadline = tuning.resultDeadline
        let expiry = DispatchWorkItem { [weak self] in self?.resultExpired(id) }
        results[id] = PressResult(pressID: c.pressID, wait: VoiceResultWait(messageID: id), durationMs: note.durationMs,
                                  expiry: expiry)
        queue.asyncAfter(deadline: .now() + deadline, execute: expiry)
        Task.detached { [self] in
            let report = await uploader.upload(note, room: room, within: deadline - (CPUClock.uptime() - endWall),
                                               surface: PocketSurface.current())
            queue.async { [self] in
                let doneWall = CPUClock.uptime(), doneCPU = CPUClock.processSeconds()
                // One line per upload, with its CPU share (background CPU budget).
                AppLog.shared.log("press", fields.merging([
                    "app": AppPhase.value, "upload_ms": Int(report.elapsed * 1000), "attempts": report.attempts,
                    "trail": report.trail, "upload_cpu_pct": (doneCPU - endCPU) / max(doneWall - endWall, 0.001) * 100,
                    "accepted": report.outcome.messageID != nil,
                ]) { a, _ in a })
                setReachable(report.outcome.failureCode != .notConnectedToServer)
                if let n = report.upgrade { ConversationStore.shared.upgradeNeeded(n) }
                if let code = report.outcome.failureCode {
                    finishResult(id, VoiceResultWait.Result(code: code, text: ""))
                } else if results[id] != nil {
                    results[id]?.acceptedGeneration = liveGeneration
                    settleAccepted([id])
                    if results[id] != nil { ensureLiveOnQueue("result_wait") }
                }
            }
        }
    }

    /// Feeds one `/live` event (not `ready`) to the presses waiting for their RESULT.
    private func settleResults(_ event: LiveEvent) {
        for (id, r) in results {
            var w = r.wait
            let out = w.handle(event)
            results[id]?.wait = w
            if let out { finishResult(id, out) }
        }
    }

    /// The one settlement path for accepted presses, run at each `ready` and at each 202: a row
    /// already seen settles RESULT 0; otherwise the current connection's `ready`, when that
    /// connection opened after the 202, settles by `ready.messages`.
    private func settleAccepted(_ ids: [String]) {
        for id in ids {
            guard var r = results[id], let accepted = r.acceptedGeneration else { continue }
            var out = r.wait.accepted()
            if out == nil, let last = lastReady, last.generation > accepted {
                out = r.wait.handle(.ready(last.ready))
            }
            results[id] = r
            if let out { finishResult(id, out) }
        }
    }

    private func resultExpired(_ id: String) {
        // The reachability of the last socket check, not the held socket, which may be stale
        // after a suspension.
        guard var r = results[id], let out = r.wait.expired(connected: serverReachable == true) else { return }
        results[id] = r
        finishResult(id, out)
    }

    /// Sends RESULT once; RESULT 0 starts the reply wait for the message.
    private func finishResult(_ id: String, _ out: VoiceResultWait.Result) {
        guard let r = results.removeValue(forKey: id) else { return }
        r.expiry.cancel()
        link.send(.result(pressID: r.pressID, code: out.code, text: out.text))
        AppLog.shared.log("press_result", ["press": r.pressID, "message_id": id, "code": out.code.rawValue,
                                           "text_len": out.text.count, "app": AppPhase.value])
        if out.code == .transcribed {
            startReplyWait(messageID: id)
            ConversationStore.shared.passportNote(messageID: id, durationMs: r.durationMs)
        }
        if results.isEmpty { pressTask.end() }
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
        // A BLE wake: answers that came while the app was suspended are rows above the cursor.
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

    /// The device waits for the answer to `messageID` (`ReplyTracker`); nil when the wait was
    /// adopted from a KEEPALIVE after a relaunch: the next answer is the reply. WORK 1 follows the
    /// message's `turn received`.
    private func startReplyWait(messageID: String?) {
        tracker.expect(messageID: messageID)
        AppLog.shared.log("reply_wait", ["message_id": messageID ?? "", "app": AppPhase.value])
        awaiting = true
        waitStarted = CPUClock.uptime()
        replyTask.begin()
        ensureLiveOnQueue("reply_wait")
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

    // MARK: /live

    /// One `/live` text frame, already decoded (called on a Go thread).
    func liveFrame(_ f: [String: Any]) {
        queue.async { [self] in handleLive(f) }
    }

    /// The `/live` connection closed from the far side.
    func liveClosed(_ why: String) {
        queue.async { [self] in
            // A replay cut short is read again from the same cursor.
            replayRows = nil
            lastReady = nil
            AppLog.shared.log("live_lost", ["reason": why, "app": AppPhase.value])
            if wantLive { ensureLiveOnQueue("reopen") }
        }
    }

    private func handleLive(_ f: [String: Any]) {
        let event = LiveEvent.decode(f)
        switch event {
        case .row(_, let e):
            settleResults(.row(seq: e.seq ?? 0, e))
            if replayRows != nil {
                replayRows?.append(e)
            } else {
                deliver(tracker.rows(ConversationStore.shared.admit([e])), source: "live")
            }
            return
        case .ready(let r):
            let replayed = liveReplays
            let rows = ConversationStore.shared.admit(replayRows ?? [])
            replayRows = nil
            ConversationStore.shared.ready(r, replayed: replayed)
            lastReady = (r, liveGeneration)
            settleAccepted(Array(results.keys))
            deliver(tracker.restore(turn: r.turn), source: "ready")
            if !replayed {
                // Rows below the room's cursor are never sent again: live answers waiting for
                // theirs are forgotten.
                tracker.forgetDelivered()
            }
            deliver(tracker.rows(rows), source: replayed ? "replay" : "ready")
            return
        case .cleaned, .failed:
            settleResults(event!)
            if case .failed(let id, .brainUnreachable) = event { deliver(tracker.messageFailed(id), source: "failed") }
        case nil:
            break
        }
        ConversationStore.shared.frame(f)
        deliver(tracker.handle(frame: f), source: "live")
    }

    /// Reads the rows above the cursor once, without the socket, and forwards an answer the
    /// device has not had (BLE wake, background refresh). `done` gets whether the rows were read,
    /// on `queue`. A fetch already running absorbs this one.
    func fetchMissed(_ reason: String, done: ((Bool) -> Void)? = nil) {
        queue.async { [self] in
            guard settings.isComplete else { done?(false); return }
            fetchWaiters.append(done)
            guard fetchWaiters.count == 1 else { return }
            let client = ChannelClient(settings: settings, tuning: tuning)
            let t0 = CPUClock.uptime()
            Task.detached { [self] in
                // Without a cursor there is nothing to catch up from: the first `ready` sets it.
                let since = ConversationStore.shared.cursor()
                var got: RowsSince?
                if let since { got = try? await client.rows(since: since) }
                queue.async { [self] in
                    var ok = since == nil
                    if let got {
                        ok = true
                        for e in got.entries { settleResults(.row(seq: e.seq ?? 0, e)) }
                        let rows = ConversationStore.shared.admit(got.entries, roomSeq: got.seq)
                        deliver(tracker.rows(rows), source: reason)
                    }
                    AppLog.shared.log("fetch_missed", ["reason": reason, "ok": ok, "rows": got?.entries.count ?? 0,
                                                       "ms": Int((CPUClock.uptime() - t0) * 1000), "link": link.state.rawValue,
                                                       "app": AppPhase.value])
                    let waiters = fetchWaiters
                    fetchWaiters = []
                    for w in waiters { w?(ok) }
                }
            }
        }
    }

    /// The connection matters while the screen is visible, while a Passport press or reply is
    /// pending, and while ambient runs (it is ambient's socket, and answers land in the thread).
    private var wantLive: Bool {
        awaiting || !results.isEmpty || AppPhase.isActive || AmbientController.shared.snapshot().isOn
    }

    /// Makes sure the `/live` connection is live (a stale one is replaced, from the stored
    /// cursor), then refreshes the room's state.
    private func ensureLiveOnQueue(_ reason: String) {
        guard settings.isComplete else { return }
        guard !liveBusy else { liveRecheck = reason; return }
        liveBusy = true
        let s = settings, tuning = tuning
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let t0 = CPUClock.uptime()
            var opened = false
            var failure: String?
            // A connection opened with the other `audio` switch is replaced too.
            if !(live.isOpen && AmbientController.shared.liveAudioCurrent && live.ping(timeout: tuning.pingTimeout)) {
                let since = ConversationStore.shared.cursor()
                queue.sync {
                    liveGeneration += 1
                    lastReady = nil
                    liveReplays = since != nil
                    replayRows = since != nil ? [] : nil
                }
                do {
                    try AmbientController.shared.openLive(s, since: since, timeout: tuning.connectTimeout)
                    opened = true
                } catch {
                    failure = "\(error)"
                }
            }
            // Room status (health, limits, date) for the conversation screen.
            if failure == nil {
                if let st = Self.fetchState(s, tuning) {
                    ConversationStore.shared.connected(st)
                } else {
                    failure = "state request failed"
                }
            }
            if failure != nil { ConversationStore.shared.connectFailed() }
            queue.async { [self] in
                liveBusy = false
                if let again = liveRecheck {
                    liveRecheck = nil
                    if wantLive { ensureLiveOnQueue(again) }
                }
                AppLog.shared.log("live", ["reason": reason, "opened": opened, "err": failure ?? "",
                                           "ms": Int((CPUClock.uptime() - t0) * 1000), "app": AppPhase.value])
                setReachable(failure == nil)
                if failure != nil, AppPhase.isActive || AmbientController.shared.snapshot().isOn {
                    // Checked again when the pause ends: the app may have left the foreground.
                    queue.asyncAfter(deadline: .now() + Self.redialDelay) { [self] in
                        if AppPhase.isActive || AmbientController.shared.snapshot().isOn { ensureLiveOnQueue("retry") }
                    }
                }
                if failure != nil, awaiting {
                    // ble-protocol §9: the answer cannot arrive without the connection.
                    // setReachable has told the device (APP_STATE 1); release it from its wait.
                    link.send(.replyDone(replyID: PocketConstants.noReplyID))
                    endReplyWait("live_lost")
                }
            }
        }
    }
}

extension PocketEngine {
    /// `GET /api/state`, or nil when the request failed. Blocking; call off `queue`.
    fileprivate static func fetchState(_ s: ChannelSettings, _ tuning: PocketTuning) -> RoomState? {
        guard let (status, body) = try? Tailnet.shared.request(method: "GET", path: ChannelPaths.state(room: s.room),
                                                               timeout: tuning.connectTimeout,
                                                               upTimeout: tuning.connectTimeout),
              status == 200 else { return nil }
        return RoomState.decode(body)
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
