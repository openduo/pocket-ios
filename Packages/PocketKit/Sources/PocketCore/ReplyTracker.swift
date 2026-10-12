// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Turns channel conversation frames into REPLY / REPLY_DONE for the Passport
/// (docs/ble-protocol.md §3, §8, §9).
///
/// - `duoduo_said` carries a text delta; the same `speech_id` is one utterance. The tracker folds
///   deltas and emits the full text so far as a non-final REPLY (replace semantics: the device
///   shows the latest full text for a reply id).
/// - `answer_final` carries the whole answer and the messages its turn covered (`message_ids`): a
///   final REPLY, then REPLY_DONE.
/// - Correlation is by `message_ids`. The device waits on its press's message; an answer whose
///   `message_ids` contains it is the reply and ends the wait. Any other answer is forwarded as
///   usual (proactive answers alert too) and the wait goes on.
/// - `turn` frames (ble-protocol §9) become WORK while a reply is expected: `received` naming the
///   waited message → 1; after it, `thinking` → 2, `tool` → 3. `idle` naming the waited message
///   means its turn ended without an answer: WORK 0, then REPLY_DONE 0, and the wait ends.
/// - Partial text is not forwarded while a message waits: `duoduo_said` names no message, so a
///   delta of another answer cannot be told apart.
/// - Reactions (`kind: "reaction"`) are filler speech, not the answer; they are skipped.
/// - Rows (`rows`): an answer row whose answer was already sent live closes that entry; an answer
///   row not seen live (its `answer_final` came while the socket was down) is delivered: the one
///   naming the waited message, else the newest of the batch. Rows arrive once, above the
///   client's cursor, so only live answers are remembered until their row arrives. This relies on
///   the channel broadcasting `answer_final` before it persists the answer's row; a row first
///   would deliver the answer twice.
/// - Reply ids come from a counter that only grows (persisted in `Memory`), so each answer has
///   its own id and the device can keep several in order. Partials and the final of one speech
///   share an id.
public struct ReplyTracker {
    public struct Answer: Equatable, Codable {
        public var replyID: UInt32
        public var text: String
        public var at: String?
    }

    /// An answer sent to the device from its live `answer_final`, kept until its row arrives.
    public struct Delivered: Equatable, Codable {
        /// Content fingerprint (`fingerprint`), so the live frame and the log row are one answer.
        public var text: UInt32
        /// The answer's `message_ids`.
        public var messages: [String]
        public var replyID: UInt32
    }

    /// What survives a relaunch, so an answer is not resent and ids keep growing.
    public struct Memory: Equatable, Codable {
        public var delivered: [Delivered] = []
        public var lastReplyID: UInt32 = 0
        /// The newest answer sent as final, so a link that comes up after a relaunch still gets
        /// it. Nil until the first answer.
        public var lastAnswer: Answer?
        /// The newest final reply id handed to a ready link. An answer accepted while the link
        /// was down has a larger id and is sent when the link comes up; one the device already
        /// got is not sent again (the Passport alerts on every REPLY). Nil until the first.
        public var linkedReplyID: UInt32?

        public init() {}
    }

    public var memory = Memory()
    public var lastAnswer: Answer? { memory.lastAnswer }

    /// The newest answer if the device has not been handed it yet: what to send when the link
    /// comes up.
    public var answerForNewLink: Answer? {
        guard let a = memory.lastAnswer, a.replyID != PocketConstants.noReplyID,
              a.replyID > (memory.linkedReplyID ?? 0) else { return nil }
        return a
    }

    /// Records that a final reply went to a ready link.
    public mutating func handedToLink(replyID: UInt32) {
        memory.linkedReplyID = max(memory.linkedReplyID ?? 0, replyID)
    }

    private var foldID = ""
    private var foldText = ""
    private var foldReplyID: UInt32 = 0

    /// The messages the device waits on (oldest first), nil when it waits on nothing. An empty
    /// list waits without an id (adopted after a relaunch): the next answer is the reply.
    public private(set) var waiting: [String]?
    public var awaiting: Bool { waiting != nil }
    /// A waited message's turn was received; work frames are its turn's from now on.
    private var received = false

    public init() {}

    /// Starts a wait, or adds a message to the running one. WORK 1 follows when the channel
    /// reports the message's delivery (`turn received`).
    public mutating func expect(messageID: String?) {
        waiting = (waiting ?? []) + (messageID.map { [$0] } ?? [])
    }

    public mutating func stopExpecting() {
        waiting = nil
        received = false
    }

    /// Whether an answer or turn with these `message_ids` is the waited one.
    private func names(_ ids: [String]) -> Bool {
        guard let w = waiting else { return false }
        return w.isEmpty || ids.contains(where: w.contains)
    }

    /// Stable 32-bit hash of a key (FNV-1a), never 0. Also names the app's per-room cache
    /// directory.
    public static func replyID(_ key: String) -> UInt32 {
        var h: UInt32 = 0x811c9dc5
        for b in key.utf8 {
            h ^= UInt32(b)
            h = h &* 0x01000193
        }
        return h == PocketConstants.noReplyID ? 1 : h
    }

    /// Content fingerprint, so the same answer seen live and later in the log is one answer.
    static func fingerprint(_ text: String) -> UInt32 { replyID("text:" + text.trimmingCharacters(in: .whitespacesAndNewlines)) }

    /// Unix seconds, the floor for reply ids. Injected by tests.
    public var clock: () -> UInt32 = { UInt32(clamping: Int(Date().timeIntervalSince1970)) }

    /// Next reply id: one more than the last, but never below the current Unix time, skipping 0
    /// (0 means "no reply"). The time floor keeps ids unique on a Passport across a reinstall,
    /// which empties `Memory`: the device stores and alerts once per id, so a reused id would be
    /// shown silently and not stored. Ids grow faster than one per second only in bursts, which
    /// the +1 covers; the floor needs the phone's clock not to go back. Unix seconds fit in a
    /// u32 until 2106.
    private mutating func nextReplyID() -> UInt32 {
        var next = memory.lastReplyID &+ 1
        if next == PocketConstants.noReplyID { next = 1 }
        memory.lastReplyID = max(next, clock())
        return memory.lastReplyID
    }

    /// Feeds one `/live` frame (already JSON-decoded). Returns messages for the device.
    public mutating func handle(frame: [String: Any]) -> [PhoneMessage] {
        switch frame["type"] as? String {
        case "duoduo_said":
            if frame["kind"] as? String == "reaction" { return [] }
            if let w = waiting, !w.isEmpty { return [] }
            let id = frame["speech_id"] as? String ?? ""
            let chunk = frame["text"] as? String ?? ""
            if !id.isEmpty, id == foldID {
                foldText += chunk
            } else {
                foldID = id
                foldText = chunk
                foldReplyID = 0
            }
            if foldText.isEmpty { return [] }
            if foldReplyID == 0 { foldReplyID = nextReplyID() }
            return [.reply(replyID: foldReplyID, final: false, text: foldText)]
        case "answer_final":
            let text = frame["text"] as? String ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
            let ids = LiveEvent.messageIDs(frame)
            var id: UInt32 = 0
            if let speech = frame["speech_id"] as? String, speech == foldID {
                id = foldReplyID
                foldID = ""; foldText = ""; foldReplyID = 0
            }
            if id == PocketConstants.noReplyID { id = nextReplyID() }
            memory.delivered.append(Delivered(text: Self.fingerprint(text), messages: ids, replyID: id))
            return accept(text: text, at: nil, replyID: id, endsWait: names(ids))
        case "turn":
            guard let w = waiting else { return [] }
            let ids = LiveEvent.messageIDs(frame)
            switch frame["phase"] as? String {
            case "received":
                guard !w.isEmpty, names(ids) else { return [] }
                received = true
                return [.work(phase: .received, label: "")]
            case "thinking":
                return received || w.isEmpty ? [.work(phase: .thinking, label: "")] : []
            case "tool":
                return received || w.isEmpty ? [.work(phase: .tool, label: "")] : []
            case "idle":
                // An answer naming the message would already have ended the wait.
                guard names(ids) else { return [] }
                stopExpecting()
                return [.work(phase: .idle, label: ""), .replyDone(replyID: PocketConstants.noReplyID)]
            default:
                return []
            }
        default:
            return []
        }
    }

    /// A waited message failed after it was sent to the brain (`brain_unreachable`): no answer
    /// will come for it. Ends the wait when it was the last one.
    public mutating func messageFailed(_ id: String) -> [PhoneMessage] {
        guard var w = waiting, w.contains(id) else { return [] }
        w.removeAll { $0 == id }
        guard w.isEmpty else { waiting = w; return [] }
        stopExpecting()
        return [.replyDone(replyID: PocketConstants.noReplyID)]
    }

    /// Feeds room-log rows above the client's cursor, oldest first: one live `row`, the replay
    /// before `ready`, or a `GET /api/imlog?since=` batch. Same test as `ImlogEntry.isAnswer`;
    /// a row of files has no text for the Passport and never counts.
    public mutating func rows(_ entries: [ImlogEntry]) -> [PhoneMessage] {
        var fresh: [ImlogEntry] = []
        for e in entries where e.isAnswer && !e.shownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fp = Self.fingerprint(e.shownText)
            if let i = memory.delivered.firstIndex(where: { $0.text == fp && Self.sameMessages($0.messages, e.message_ids) }) {
                memory.delivered.remove(at: i)
            } else {
                fresh.append(e)
            }
        }
        if let w = waiting, !w.isEmpty, let e = fresh.first(where: { names($0.message_ids ?? []) }) {
            return accept(text: e.shownText, at: e.at, replyID: nextReplyID(), endsWait: true)
        }
        guard let e = fresh.last else { return [] }
        return accept(text: e.shownText, at: e.at, replyID: nextReplyID(), endsWait: waiting?.isEmpty == true)
    }

    /// Live answers whose rows will never come above the cursor (a connection opened without
    /// one starts at the room's newest row): forget them.
    public mutating func forgetDelivered() { memory.delivered = [] }

    /// `message_ids` match (a row without the field has none).
    static func sameMessages(_ a: [String], _ b: [String]?) -> Bool { Set(a) == Set(b ?? []) }

    /// `ready.turn` after a reconnect: when the open turn names a waited message, its delivery was
    /// missed live; WORK 1 and the turn's current phase follow.
    public mutating func restore(turn: LiveEvent.TurnSnapshot?) -> [PhoneMessage] {
        guard let turn, let w = waiting, !w.isEmpty, !received, names(turn.messageIDs) else { return [] }
        received = true
        var out: [PhoneMessage] = [.work(phase: .received, label: "")]
        switch turn.phase {
        case "thinking": out.append(.work(phase: .thinking, label: ""))
        case "tool": out.append(.work(phase: .tool, label: ""))
        default: break
        }
        return out
    }

    /// Sends an answer as final; ends the wait when it is the waited one.
    private mutating func accept(text: String, at: String?, replyID id: UInt32, endsWait: Bool) -> [PhoneMessage] {
        if id >= (memory.lastAnswer?.replyID ?? 0) { memory.lastAnswer = Answer(replyID: id, text: text, at: at) }
        if endsWait { stopExpecting() }
        return [.reply(replyID: id, final: true, text: text), .replyDone(replyID: id)]
    }
}
