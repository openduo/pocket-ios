// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import PocketCore

/// What the conversation screen shows. Built off the main thread, published on change while the
/// app is active.
struct ChatSnapshot: Equatable {
    enum Connection: Equatable {
        case connecting
        case online
        /// The display socket could not be restored (design Q9: after the first failed attempt).
        case offline
    }

    enum Older: Equatable {
        case idle
        case loading
        /// No rows in the scanned days before the oldest one shown.
        case exhausted(before: String)
    }

    var rows: [ThreadRow] = []
    var connection = Connection.connecting
    var room: RoomState?
    var working: TurnState.Working?
    var lastHeard: String?
    var cachedAt: Date?
    var older = Older.idle
    var hasHistory = false
    var configured = false
}

/// The single source of the thread (design §9): offline cache + live frames + outbox. Shared by
/// the screen and the Passport path (both feed it), so they never disagree. All state lives on
/// `queue`; nothing here touches UI.
final class ConversationStore: @unchecked Sendable {
    static let shared = ConversationStore()

    /// Days scanned backwards per "load earlier" before reporting "no earlier rows". Each probe is
    /// one small `GET /api/imlog`; the user can continue the scan. Chosen, no data.
    static let historyScanDays = 14

    let queue = DispatchQueue(label: "pocket.chat", qos: .userInitiated)
    private var settings = ChannelSettings.load()
    private var tuning = PocketTuning.load()
    private var cache: HistoryCache?
    private var outbox: OutboxStore?
    private var roomDir: URL?
    private var turn = TurnState()
    private var durations: [String: Int] = [:]
    private var recordLost = Set<String>()
    private var notes: [(at: Date, text: String)] = []
    private var room: RoomState?
    private var connection = ChatSnapshot.Connection.connecting
    private var lastHeard: String?
    private var older = ChatSnapshot.Older.idle
    private var pumping = false

    private let snapLock = NSLock()
    private var snap = ChatSnapshot()
    private var dirty = true
    private var publishPending = false
    /// Called on the main queue after the snapshot changed (coalesced).
    var onChange: (() -> Void)?

    private init() {
        queue.async { self.configure() }
    }

    func snapshot() -> ChatSnapshot {
        snapLock.lock(); defer { snapLock.unlock() }
        return snap
    }

    private var client: ChannelClient { ChannelClient(settings: settings, tuning: tuning) }

    // MARK: configuration

    /// Opens the cache of the configured room (one directory per host and room).
    private func configure() {
        settings = ChannelSettings.load()
        tuning = PocketTuning.load()
        guard settings.isComplete else {
            cache = nil
            outbox = nil
            changed()
            return
        }
        // Try-it mode keeps its room in a temporary directory that is removed on exit.
        let base = TryMode.active ? TryMode.cacheBase
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let id = ReplyTracker.replyID("\(settings.host.lowercased())|\(settings.room)")
        let dir = base.appendingPathComponent("rooms/\(String(id, radix: 16))", isDirectory: true)
        roomDir = dir
        cache = HistoryCache(directory: dir.appendingPathComponent("imlog", isDirectory: true))
        outbox = OutboxStore(directory: dir.appendingPathComponent("outbox", isDirectory: true))
        if let d = try? Data(contentsOf: dir.appendingPathComponent("voice-durations.json")),
           let m = try? JSONDecoder().decode([String: Int].self, from: d) {
            durations = m
        }
        turn = TurnState()
        room = nil
        older = .idle
        connection = .connecting
        changed()
    }

    func settingsChanged() { queue.async { self.configure() } }

    private func saveDurations() {
        guard let dir = roomDir, let d = try? JSONEncoder().encode(durations) else { return }
        try? d.write(to: dir.appendingPathComponent("voice-durations.json"), options: .atomic)
    }

    // MARK: connection (called by PocketEngine's display socket management)

    /// The display socket is open and `/api/state` answered: refresh today's log (and any days
    /// missed since the last fetch), then send what is queued.
    func connected(_ state: RoomState) {
        queue.async { [self] in
            room = state
            connection = .online
            changed()
            refreshDays(today: state.date)
            pump()
        }
    }

    func connectFailed() {
        queue.async { [self] in
            guard connection != .offline else { return }
            connection = .offline
            changed()
        }
    }

    /// Day of a log row: the row's local calendar day (the channel writes one file per local day;
    /// the phone and the channel host are the user's own devices in one time zone).
    private func day(of e: ImlogEntry) -> String {
        if let d = ThreadBuilder.parse(e.at) { return DayString.local(d) }
        return room?.date ?? DayString.local(Date())
    }

    private func refreshDays(today: String) {
        guard let cache, DayString.isValid(today) else { return }
        // Days from the newest cached day through today; with an empty cache, today only.
        var days = [today]
        if let last = cache.cachedDays.last, last < today {
            days = [last] + DayString.range(after: last, through: today)
        }
        let c = client
        Task.detached { [self] in
            for d in days {
                guard let entries = try? await c.imlog(date: d) else { continue }
                queue.async { [self] in
                    // An empty past day with nothing cached is not worth a file.
                    if entries.isEmpty, cache.entries(d).isEmpty, d != today { return }
                    cache.replace(day: d, entries: entries)
                    outbox?.mutate { $0.reconcile(with: entries) }
                    turn.settle(with: entries)
                    endTurnIfAnswered()
                    changed()
                }
            }
        }
    }

    /// Ends the working bubble when the cached log already holds an answer after its notes. The
    /// two newest cached days cover a question asked before midnight and answered after it.
    private func endTurnIfAnswered() {
        guard let cache, !(turn.working?.notes.isEmpty ?? true) else { return }
        let days = cache.cachedDays.suffix(2)
        if turn.endIfAnswered(in: days.flatMap { cache.entries($0) }) { changed() }
    }

    // MARK: live frames

    func frame(_ f: [String: Any]) {
        queue.async { [self] in
            var visible = turn.handle(frame: f)
            switch f["type"] as? String {
            case "imlog_append":
                let entries = ImlogEntry.decodeList(f["entries"])
                for e in entries { cache?.append(day: day(of: e), entries: [e]) }
                outbox?.mutate { $0.reconcile(with: entries) }
                turn.settle(with: entries)
                endTurnIfAnswered()
                visible = true
            case "transcript":
                if let row = f["row"] as? [String: Any], let t = row["text"] as? String, !t.isEmpty {
                    let speaker = (row["speaker"] as? String).flatMap { $0 == "V?" ? nil : $0 }
                    lastHeard = speaker.map { "\($0)  \(t)" } ?? t
                    visible = true
                }
            case "record_unavailable":
                if let u = f["utt_id"] as? String { recordLost.insert(u); visible = true }
            case "understood":
                if f["addressed"] as? Bool == false { notes.append((Date(), String(localized: "听到了，不是在叫我"))); visible = true }
            case "wake_ignored":
                notes.append((Date(), String(localized: "听到了，不是在叫我"))); visible = true
            case "ack_silenced":
                notes.append((Date(), String(localized: "听到了，这次没有另外回应"))); visible = true
            case "cerebellum":
                if let ok = f["ok"] as? Bool { room?.cerebellumOK = ok; visible = true }
            default:
                break
            }
            if visible { changed() }
        }
    }

    /// The display socket was reopened after a drop: a missed `idle` must not leave a spinner.
    func displayReopened() {
        queue.async { [self] in
            if turn.working != nil { turn.reset(); changed() }
        }
    }

    /// A Passport voice note was transcribed: remember its length for the bubble head, and show
    /// the working bubble for it.
    func passportNote(uttID: String?, durationMs: Int) {
        queue.async { [self] in
            if let uttID { durations[uttID] = durationMs; saveDurations() }
            turn.expect(uttID: uttID)
            // The answer may already be logged (it arrived while the display socket was down).
            endTurnIfAnswered()
            changed()
        }
    }

    // MARK: sending

    func sendText(_ text: String, attachments: [ChannelAttachment]) {
        queue.async { [self] in
            outbox?.mutate { $0.add(OutboxItem(body: .text(text, attachments: attachments))) }
            changed()
            pump()
        }
    }

    func sendVoice(_ packets: [Data]) {
        queue.async { [self] in
            guard let outbox else { return }
            let note = VoiceNote(source: .phone, packets: packets)
            do { try outbox.saveVoice(note) } catch {
                AppLog.shared.log("voice_save_error", ["err": "\(error)"])
                return
            }
            outbox.mutate { $0.add(OutboxItem(body: .voice(voiceID: note.id, durationMs: note.durationMs))) }
            changed()
            pump()
        }
    }

    func retry(_ id: UUID) {
        queue.async { [self] in
            outbox?.mutate { $0.set(id, .queued) }
            changed()
            pump()
        }
    }

    func delete(_ id: UUID) {
        queue.async { [self] in
            outbox?.mutate { $0.remove(id) }
            changed()
        }
    }

    /// Sends queued items one at a time, oldest first, so they reach the brain in order.
    private func pump() {
        guard !pumping, connection == .online, let outbox, let item = outbox.outbox.sendable().first else { return }
        pumping = true
        outbox.mutate { $0.set(item.id, .sending) }
        changed()
        let c = client, room = settings.room, tuning = tuning, state = self.room
        Task.detached { [self] in
            let result: OutboxItem.State
            var duration: (String, Int)?
            var drop = false
            var transportDown = false
            switch item.body {
            case .text(let text, let attachments):
                do {
                    let r = try await c.inject(text: text, attachments: attachments)
                    result = .delivered(uttID: r.uttID, at: r.at, transcript: nil, recordAvailable: r.recordAvailable)
                } catch let e as ChannelError where e.isTransport {
                    result = .queued
                    transportDown = true
                } catch {
                    AppLog.shared.log("inject_error", ["err": "\(error)"])
                    result = .failed(reason: String(localized: "没发出去 · 轻点重试"))
                }
            case .voice(let vid, let ms):
                guard let note = await self.loadVoice(vid) else {
                    result = .failed(reason: String(localized: "录音丢失"))
                    break
                }
                if UploadPolicy.check(size: (try? note.body().count) ?? 0, state: state) != .ok {
                    result = .failed(reason: String(localized: "录音太长，超过上传上限"))
                    break
                }
                let uploader = VoiceUploader(transport: TsnetTransport(tuning: tuning), tuning: tuning)
                let r = await uploader.upload(note, room: room)
                AppLog.shared.log("phone_note", ["voice_id": vid.uuidString.lowercased(), "packets": note.packets.count,
                                                 "code": r.outcome.resultCode.rawValue, "attempts": r.attempts,
                                                 "upload_ms": Int(r.elapsed * 1000), "trail": r.trail])
                switch r.outcome {
                case .transcribed(let text, let utt):
                    result = .delivered(uttID: utt, at: nil, transcript: text, recordAvailable: true)
                    if let utt { duration = (utt, ms) }
                case .empty:
                    result = .queued
                    drop = true
                case .asrFailed:
                    result = .failed(reason: String(localized: "识别出错 · 轻点重试"))
                case .sendFailed(let why) where why.hasPrefix("503"):
                    result = .failed(reason: String(localized: "语音服务暂不可用 · 轻点重试"))
                case .sendFailed(let why) where why.hasPrefix("413"):
                    result = .failed(reason: String(localized: "录音太长，超过上传上限"))
                case .sendFailed:
                    result = .failed(reason: String(localized: "没发出去 · 轻点重试"))
                case .notConnected:
                    result = .queued
                    transportDown = true
                }
            }
            queue.async { [self] in
                pumping = false
                if drop {
                    self.outbox?.mutate { $0.remove(item.id) }
                    notes.append((Date(), String(localized: "没听清，再说一次")))
                } else {
                    self.outbox?.mutate { $0.set(item.id, result) }
                }
                if case .delivered(let utt, _, _, _) = result {
                    turn.expect(uttID: utt)
                    endTurnIfAnswered()
                }
                if let (u, ms) = duration { durations[u] = ms; saveDurations() }
                if transportDown {
                    connection = .offline
                    PocketEngine.shared.connectionLost()
                }
                changed()
                pump()
            }
        }
    }

    private func loadVoice(_ id: UUID) async -> VoiceNote? {
        await withCheckedContinuation { c in queue.async { c.resume(returning: self.outbox?.loadVoice(id)) } }
    }

    // MARK: older history

    /// Fetches days before the oldest cached day until one has rows, up to `historyScanDays`.
    func loadOlder() {
        queue.async { [self] in
            guard let cache, older != .loading, connection == .online else { return }
            let oldest: String
            if case .exhausted(let before) = older {
                oldest = before
            } else {
                oldest = cache.cachedDays.first ?? room?.date ?? DayString.local(Date())
            }
            older = .loading
            changed()
            let c = client
            Task.detached { [self] in
                var day = oldest
                var found: (String, [ImlogEntry])?
                var failed = false
                for _ in 0..<Self.historyScanDays {
                    guard let prev = DayString.adding(-1, to: day) else { break }
                    day = prev
                    do {
                        let e = try await c.imlog(date: day)
                        if !e.isEmpty { found = (day, e); break }
                    } catch {
                        failed = true
                        break
                    }
                }
                queue.async { [self] in
                    if let (d, e) = found {
                        cache.replace(day: d, entries: e)
                        older = .idle
                    } else {
                        older = failed ? .idle : .exhausted(before: day)
                    }
                    changed()
                }
            }
        }
    }

    // MARK: publish

    private func changed() {
        dirty = true
        guard AppPhase.isActive else { return }
        schedulePublish()
    }

    /// The app became active: build the snapshot once from whatever changed while away.
    func appBecameActive() {
        queue.async { [self] in if dirty { schedulePublish() } }
    }

    private func schedulePublish() {
        guard !publishPending else { return }
        publishPending = true
        // Coalesce: every change queued before this runs lands in one build.
        queue.async { [self] in
            publishPending = false
            build()
            DispatchQueue.main.async { self.onChange?() }
        }
    }

    private func build() {
        dirty = false
        var s = ChatSnapshot()
        s.configured = settings.isComplete
        if let cache {
            let entries = cache.all()
            s.rows = ThreadBuilder().build(.init(entries: entries, outbox: outbox?.outbox.items ?? [], turn: turn,
                                                 durations: durations, recordLost: recordLost, notes: notes))
            s.hasHistory = !entries.isEmpty || !(outbox?.outbox.items.isEmpty ?? true)
            s.cachedAt = cache.lastFetch
        }
        s.connection = connection
        s.room = room
        s.working = turn.working
        s.lastHeard = lastHeard
        s.older = older
        snapLock.lock()
        snap = s
        snapLock.unlock()
    }
}
