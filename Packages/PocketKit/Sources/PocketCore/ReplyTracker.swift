// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Turns channel conversation frames into REPLY / REPLY_DONE for the Passport
/// (docs/ble-protocol.md §3, §8, §9).
///
/// - `duoduo_said` carries a text delta; the same `speech_id` is one utterance. The tracker folds
///   deltas and emits the full text so far as a non-final REPLY (replace semantics: the device
///   shows the latest full text for a reply id).
/// - `answer_final` carries the whole answer: a final REPLY, then REPLY_DONE.
/// - `turn` frames (ble-protocol §9) become WORK while a reply is expected: `thinking` → 2, `tool` → 3.
///   `idle` means the brain finished without an answer: WORK 0, then REPLY_DONE 0, and the wait
///   ends. Other turn phases (`received`, `speaking`, `done`) are not work phases.
/// - Reactions (`kind: "reaction"`) are filler speech, not the answer; they are skipped.
/// - After a wake, `catchUp` reads the room log for an answer that arrived while the socket was
///   down. The server log is authoritative; an answer already sent is not sent again.
/// - Pocket is one conversation: while notes wait, the first answer that arrives after they were
///   sent is the reply, whatever `utt_id` it carries (the brain answers notes folded into one turn
///   under the earliest note's id). Live, that is the first `answer_final` after `expect`; in the
///   log, the first answer row after the earliest waiting note's typed row (`LogCorrelation`).
///   Partial text is not forwarded while a note waits: a delta of an answer that began before the
///   note cannot be told apart. Without an `utt_id` the log's newest unsent answer is the reply.
///   With no reply expected, every answer is forwarded.
/// - Reply ids come from a counter that only grows (persisted in `Memory`), so each answer has
///   its own id and the device can keep several in order. Partials and the final of one speech
///   share an id; an answer sent again (link ready, closing a wait) keeps the id it was sent with.
public struct ReplyTracker {
    public struct Answer: Equatable, Codable {
        public var replyID: UInt32
        public var text: String
        public var at: String?
    }

    /// An answer already sent to the device as final.
    public struct Delivered: Equatable, Codable {
        /// Content fingerprint (`fingerprint`), so the live frame and the log row are one answer.
        public var text: UInt32
        /// The utterance the answer names; nil for log rows without one and proactive messages.
        public var utt: String?
        /// 0 for entries carried over from builds that did not record it.
        public var replyID: UInt32
    }

    /// What survives a relaunch, so the last answer is not resent and ids keep growing.
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

    /// The notes the device waits on (utt ids, oldest first), nil when it waits on nothing. An
    /// empty list waits without an id: the next answer is the reply.
    public private(set) var waiting: [String]?
    public var awaiting: Bool { waiting != nil }

    public init() {}

    /// Starts a wait, or adds a note to the running one. Returns WORK 1 for the device
    /// (ble-protocol §9: sent when the wait starts).
    @discardableResult
    public mutating func expect(uttID: String?) -> [PhoneMessage] {
        waiting = (waiting ?? []) + (uttID.map { [$0] } ?? [])
        return [.work(phase: .received, label: "")]
    }

    public mutating func stopExpecting() { waiting = nil }

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

    /// Feeds one display-socket frame (already JSON-decoded). Returns messages for the device.
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
            let speech = frame["speech_id"] as? String
            var reuse: UInt32 = 0
            if let speech, speech == foldID {
                reuse = foldReplyID
                foldID = ""; foldText = ""; foldReplyID = 0
            }
            return accept(text: text, utt: frame["utt_id"] as? String, at: nil, reuse: reuse, closeOnRepeat: awaiting)
        case "turn":
            guard waiting != nil else { return [] }
            switch frame["phase"] as? String {
            case "thinking": return [.work(phase: .thinking, label: "")]
            case "tool": return [.work(phase: .tool, label: "")]
            case "idle":
                // An answer would already have ended the wait.
                waiting = nil
                return [.work(phase: .idle, label: ""), .replyDone(replyID: PocketConstants.noReplyID)]
            default: return []
            }
        default:
            return []
        }
    }

    /// Feeds room-log entries (`/api/state` `imlog`, oldest first). While notes wait, delivers the
    /// first answer logged after they were sent; otherwise the newest answer if it was not sent
    /// yet. Same test as `ImlogEntry.isAnswer`: reaction fillers (「我看看」) are not answers.
    public mutating func catchUp(entries: [[String: Any]]) -> [PhoneMessage] {
        // A row of files 多多 sent has no text; the Passport shows text, so it never counts.
        let isAnswer = { (e: [String: Any]) in
            (e["kind"] as? String) != "reaction"
                && ((e["kind"] as? String) == "answer" || (e["speaker"] as? String) == ImlogEntry.duoduoLabel)
                && !((e["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let notes = waiting, !notes.isEmpty {
            guard let i = LogCorrelation.firstAnswerIndex(after: Set(notes), in: entries, uttID: { $0["utt_id"] as? String },
                                                          isAnswer: isAnswer),
                  let text = entries[i]["text"] as? String else { return [] }
            return accept(text: text, utt: entries[i]["utt_id"] as? String, at: entries[i]["at"] as? String,
                          reuse: 0, closeOnRepeat: true)
        }
        guard let e = entries.last(where: isAnswer), let text = e["text"] as? String else { return [] }
        return accept(text: text, utt: e["utt_id"] as? String, at: e["at"] as? String, reuse: 0, closeOnRepeat: false)
    }

    /// Sends an answer as final and ends any wait. An answer already sent is skipped, unless
    /// `closeOnRepeat`: it is the reply a waiting device needs, so it goes again under the id it
    /// was first sent with (the device replaces by id, so nothing new appears).
    private mutating func accept(text: String, utt: String?, at: String?, reuse: UInt32, closeOnRepeat: Bool) -> [PhoneMessage] {
        let fp = Self.fingerprint(text)
        var id = reuse
        var known = utt
        if let i = memory.delivered.lastIndex(where: { $0.text == fp && ($0.utt == nil || utt == nil || $0.utt == utt) }) {
            guard closeOnRepeat else { return [] }
            let old = memory.delivered.remove(at: i)
            if old.replyID != PocketConstants.noReplyID { id = old.replyID }
            known = utt ?? old.utt
        }
        if id == PocketConstants.noReplyID { id = nextReplyID() }
        memory.delivered.append(Delivered(text: fp, utt: known, replyID: id))
        let window = PocketConstants.catchUpWindowRows
        if memory.delivered.count > window { memory.delivered.removeFirst(memory.delivered.count - window) }
        // A repeat closing a wait has an older id; the newest answer stays the one to replay.
        if id >= (memory.lastAnswer?.replyID ?? 0) { memory.lastAnswer = Answer(replyID: id, text: text, at: at) }
        waiting = nil
        return [.reply(replyID: id, final: true, text: text), .replyDone(replyID: id)]
    }
}
