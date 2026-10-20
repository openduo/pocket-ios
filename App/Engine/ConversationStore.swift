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
        /// The `/live` connection could not be restored (design Q9: after the first failed attempt).
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
    /// Which side must be upgraded, when the channel said so.
    var upgrade: UpgradeNotice?
}

/// The single source of the thread (design §9): offline cache + live frames + outbox. Shared by
/// the screen and the Passport path (both feed it), so they never disagree. All state lives on
/// `queue`; nothing here touches UI.
///
/// It holds the room's cursor: the `seq` of the newest row in the cache, persisted with it. The
/// `/live` connection asks for the rows after it (`since`), so a reconnect misses nothing; without
/// a cursor (a new room) the first `ready` sets it and history is loaded by day.
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
    private var rowCursor = RowCursor()
    /// A connection without a cursor became ready: load history by day once the room's date is
    /// known.
    private var historyPending = false
    private var durations: [String: Int] = [:]
    /// Messages whose delivery to the brain failed after their row was written (seen live).
    private var undelivered = Set<String>()
    private var upgrade: UpgradeNotice?
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
        rowCursor = (try? Data(contentsOf: dir.appendingPathComponent("cursor.json")))
            .flatMap { try? JSONDecoder().decode(RowCursor.self, from: $0) } ?? RowCursor()
        historyPending = false
        undelivered = []
        turn = TurnState()
        room = nil
        older = .idle
        connection = .connecting
        changed()
    }

    func settingsChanged() { queue.async { self.configure() } }

    private func saveCursor() {
        guard let dir = roomDir, let d = try? JSONEncoder().encode(rowCursor) else { return }
        try? d.write(to: dir.appendingPathComponent("cursor.json"), options: .atomic)
    }

    private func saveDurations() {
        guard let dir = roomDir, let d = try? JSONEncoder().encode(durations) else { return }
        try? d.write(to: dir.appendingPathComponent("voice-durations.json"), options: .atomic)
    }

    // MARK: connection (called by PocketEngine's `/live` management)

    /// The `/live` connection is open and `/api/state` answered: send what is queued.
    func connected(_ state: RoomState) {
        queue.async { [self] in
            room = state
            connection = .online
            changed()
            if historyPending {
                historyPending = false
                refreshDays(today: state.date)
            }
            pump()
        }
    }

    /// The room's cursor, for `since` (nil before the first `ready`). Called off `queue`.
    func cursor() -> Int? { queue.sync { cache == nil ? nil : rowCursor.seq } }

    /// Rows from `/live` (one live row, or the replay before `ready`) or from
    /// `GET /api/imlog?since=` (with `roomSeq`). Keeps the rows above the cursor, persists them
    /// and the cursor, and returns them (oldest first) for the reply tracker. Called off `queue`.
    func admit(_ rows: [ImlogEntry], roomSeq: Int? = nil) -> [ImlogEntry] {
        queue.sync { [self] in
            guard let cache else { return [] }
            let fresh = rows.sorted { ($0.seq ?? 0) < ($1.seq ?? 0) }.filter { e in e.seq.map { rowCursor.admit($0) } ?? true }
            var byDay: [String: [ImlogEntry]] = [:]
            var days: [String] = []
            for e in fresh {
                let d = day(of: e)
                if byDay[d] == nil { days.append(d) }
                byDay[d, default: []].append(e)
            }
            for d in days { cache.append(day: d, entries: byDay[d] ?? []) }
            if let roomSeq { rowCursor.reached(roomSeq) }
            // The rows are on disk before the cursor that names them.
            if !fresh.isEmpty || roomSeq != nil { saveCursor() }
            guard !fresh.isEmpty else { return [] }
            outbox?.mutate { $0.reconcile(with: fresh) }
            turn.settle(with: fresh)
            endTurnIfAnswered()
            changed()
            return fresh
        }
    }

    /// `ready`: the room's cursor and snapshot. After a replay, a message the outbox still holds
    /// as accepted that is neither listed nor logged failed (its reason is lost). Called off
    /// `queue`, after the replayed rows were admitted.
    func ready(_ r: LiveEvent.Ready, replayed: Bool) {
        queue.sync { [self] in
            // An app update is only cleared by installing it; a channel notice follows each `ready`.
            if upgrade != .appUpdate, upgrade != UpgradeNotice.of(r) {
                upgrade = UpgradeNotice.of(r)
                changed()
            }
            guard cache != nil else { return }
            rowCursor.reached(r.seq)
            saveCursor()
            turn.restore(r.turn)
            if replayed {
                for item in outbox?.outbox.items ?? [] where item.isAccepted {
                    // Logged items were reconciled away with their rows.
                    if case .failed = MessageSettlement.of(item.messageID, ready: r, rowLogged: false) {
                        outbox?.mutate { $0.set(item.id, .failed(reason: String(localized: "没发出去 · 轻点重试"))) }
                    }
                }
            } else if let room {
                refreshDays(today: room.date)
            } else {
                historyPending = true
            }
            changed()
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

    /// Ends the working bubble when the cached log already holds an answer naming its messages.
    /// The two newest cached days cover a question asked before midnight and answered after it.
    private func endTurnIfAnswered() {
        guard let cache, !(turn.working?.messages.isEmpty ?? true) else { return }
        let days = cache.cachedDays.suffix(2)
        if turn.endIfAnswered(in: days.flatMap { cache.entries($0) }) { changed() }
    }

    // MARK: live frames

    func frame(_ f: [String: Any]) {
        queue.async { [self] in
            var visible = turn.handle(frame: f)
            switch LiveEvent.decode(f) {
            case .cleaned(let id, let text):
                // The bubble shows the text the brain receives, never the raw transcript.
                // It can beat the 202 to the phone; an item still sending is accepted by it.
                if let item = outbox?.outbox.item(messageID: id) {
                    switch item.state {
                    case .accepted(let at, _):
                        outbox?.mutate { $0.set(item.id, .accepted(at: at, cleaned: text)) }
                        visible = true
                    case .sending:
                        outbox?.mutate { $0.set(item.id, .accepted(at: nil, cleaned: text)) }
                        visible = true
                    case .queued, .failed:
                        break
                    }
                }
            case .failed(let id, let reason):
                visible = messageFailed(id, reason) || visible
            default:
                break
            }
            switch f["type"] as? String {
            case "transcript":
                if let row = f["row"] as? [String: Any], let t = row["text"] as? String, !t.isEmpty {
                    let speaker = (row["speaker"] as? String).flatMap { $0 == "V?" ? nil : $0 }
                    lastHeard = speaker.map { "\($0)  \(t)" } ?? t
                    visible = true
                }
            case "understood":
                if f["addressed"] as? Bool == false { notes.append((Date(), String(localized: "听到了，不是在叫我"))); visible = true }
            case "wake_ignored":
                notes.append((Date(), String(localized: "听到了，不是在叫我"))); visible = true
            case "ack_silenced":
                notes.append((Date(), String(localized: "听到了，这次没有另外回应"))); visible = true
            case "cerebellum":
                if let ok = f["ok"] as? Bool {
                    room?.cerebellumOK = ok
                    // A cerebellum that accepted the channel has, by then, the same major.
                    if ok { room?.cerebellumMismatch = false }
                    visible = true
                }
            default:
                break
            }
            if visible { changed() }
        }
    }

    /// A response said the app or the channel must be upgraded (the Passport path reports here too).
    func upgradeNeeded(_ n: UpgradeNotice) {
        queue.async { [self] in noteUpgrade(n) }
    }

    /// An app update outranks a channel upgrade: an app too old for its channel says so first.
    private func noteUpgrade(_ n: UpgradeNotice) {
        guard upgrade != .appUpdate, upgrade != n else { return }
        upgrade = n
        changed()
    }

    /// `message failed`: the outbox item shows why. Returns whether anything visible changed.
    private func messageFailed(_ id: String, _ reason: MessageFailure) -> Bool {
        if case .brainUnreachable = reason {
            // The row stays (append-only record); its bubble says it did not reach 多多.
            undelivered.insert(id)
            turn.messageFailed(id)
            return true
        }
        guard let item = outbox?.outbox.item(messageID: id) else { return false }
        switch reason {
        case .emptyTranscript:
            outbox?.mutate { $0.remove(item.id) }
            notes.append((Date(), String(localized: "没听清，再说一次")))
        case .asrFailed:
            outbox?.mutate { $0.set(item.id, .failed(reason: String(localized: "识别出错 · 轻点重试"))) }
        case .perceptionUnavailable:
            outbox?.mutate { $0.set(item.id, .failed(reason: String(localized: "语音服务暂不可用 · 轻点重试"))) }
        case .brainUnreachable, .other:
            outbox?.mutate { $0.set(item.id, .failed(reason: String(localized: "没发出去 · 轻点重试"))) }
        }
        return true
    }

    /// A Passport voice note's text is known: remember its length for the bubble head.
    func passportNote(messageID: String, durationMs: Int) {
        queue.async { [self] in
            durations[messageID] = durationMs
            saveDurations()
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

    /// Sends queued items one at a time, oldest first, so they reach the brain in order. Each is
    /// one message under its fixed key; a 202 means the channel holds it, and its row (or a
    /// `message failed`) follows on `/live`.
    private func pump() {
        guard !pumping, connection == .online, let outbox, let item = outbox.outbox.sendable().first else { return }
        pumping = true
        outbox.mutate { $0.set(item.id, .sending) }
        changed()
        let c = client, room = settings.room, tuning = tuning, state = self.room
        Task.detached { [self] in
            let result: OutboxItem.State
            var duration: (String, Int)?
            var transportDown = false
            var notice: UpgradeNotice?
            switch item.body {
            case .text(let text, let attachments):
                do {
                    let r = try await c.sendMessage(text: text, attachments: attachments, key: item.messageID)
                    result = .accepted(at: r.at, cleaned: nil)
                } catch let e as ChannelError where e.isTransport {
                    result = .queued
                    transportDown = true
                } catch ChannelError.http(401, _) where DeviceCredentials.shared.unauthorized {
                    // Not the message's fault: it goes out once the device is paired again.
                    result = .queued
                    transportDown = true
                } catch ChannelError.http(let status, let error) {
                    AppLog.shared.log("message_error", ["err": "\(status) \(error)"])
                    notice = UpgradeNotice.of(status: status, error: error)
                    result = .failed(reason: String(localized: "没发出去 · 轻点重试"))
                } catch {
                    AppLog.shared.log("message_error", ["err": "\(error)"])
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
                let place = ArrivalMonitor.shared.report()
                let r = await uploader.upload(note, room: room, surface: PocketSurface.current(), place: place)
                ArrivalMonitor.shared.settle(place, accepted: r.outcome.messageID != nil)
                notice = r.upgrade
                AppLog.shared.log("phone_note", ["message_id": item.messageID, "packets": note.packets.count,
                                                 "accepted": r.outcome.messageID != nil, "attempts": r.attempts,
                                                 "upload_ms": Int(r.elapsed * 1000), "trail": r.trail])
                switch r.outcome {
                case .accepted(let id):
                    result = .accepted(at: nil, cleaned: nil)
                    duration = (id, ms)
                case .sendFailed where DeviceCredentials.shared.unauthorized:
                    result = .queued
                    transportDown = true
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
                // The row or a failure may already have arrived; only an item still sending moves.
                if let cur = self.outbox?.outbox.items.first(where: { $0.id == item.id }), cur.state == .sending {
                    self.outbox?.mutate { $0.set(item.id, result) }
                }
                if let (u, ms) = duration { durations[u] = ms; saveDurations() }
                if let notice { noteUpgrade(notice) }
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
                                                 durations: durations, undelivered: undelivered, notes: notes))
            s.hasHistory = !entries.isEmpty || !(outbox?.outbox.items.isEmpty ?? true)
            s.cachedAt = cache.lastFetch
        }
        s.connection = connection
        s.room = room
        s.working = turn.working
        s.lastHeard = lastHeard
        s.older = older
        s.upgrade = upgrade
        snapLock.lock()
        snap = s
        snapLock.unlock()
    }
}
