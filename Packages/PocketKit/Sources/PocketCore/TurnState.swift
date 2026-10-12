// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// 多多's working bubble (design §4.4), driven by `/live` frames.
///
/// - A turn starts on `turn received` (the channel delivered an input to the brain: this phone's
///   message, a Passport note, typed text from another screen, ambient speech). Its
///   `message_ids` are the messages the bubble works on.
/// - `thinking` / `tool` frames update the phase. Tool frames become steps by the Feishu process
///   card's rules (`ToolLine`): per call the channel sends `label` = name (claude's early call
///   without input), `label` + `input_summary` (the full call), and `label` = `<name> ✓` (the
///   result). The first two fill one step; the result marks the oldest open step of that name
///   done. The channel drops `tool_use_id`, so parallel calls of one tool pair up in order.
/// - `duoduo_said` deltas (not reactions) stream the answer text, folded by `speech_id`.
/// - Correlation is by `message_ids`. An `answer_final` or `turn idle` naming one of the bubble's
///   messages, or any one when the bubble has none, ends it; an answer to other inputs leaves a
///   provisional answer and the bubble goes on. A turn can cover several messages (the brain
///   folds inputs sent while it works into its turn).
/// - After a reconnect `ready.turn` restores the bubble (`restore`).
public struct TurnState: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case received, thinking, tool, streaming
    }

    public struct Step: Equatable, Sendable {
        /// Display name (`mcp__server__tool` → `tool`).
        public var name: String
        /// One-row summary of the input, nil when there is none.
        public var summary: String?
        public var done: Bool
        /// The frame carrying the input arrived (a later one starts a new step).
        public var hasInput: Bool

        public init(name: String, summary: String? = nil, done: Bool = false, hasInput: Bool = false) {
            self.name = name
            self.summary = summary
            self.done = done
            self.hasInput = hasInput
        }

        /// `<name> <summary>`, the Feishu tool line.
        public var line: String { summary.map { "\(name) \($0)" } ?? name }
    }

    /// The tool steps of one answered turn, for the collapsed line above the answer.
    public struct Trace: Equatable, Sendable {
        public var steps: [Step]
        /// From the turn's first frame to its answer; nil when the start was not seen.
        public var elapsed: TimeInterval?

        public init(steps: [Step], elapsed: TimeInterval? = nil) {
            self.steps = steps
            self.elapsed = elapsed
        }

        public static let empty = Trace(steps: [])

        /// The collapsed line: Feishu's finished title 「任务已完成」 with the step count and the
        /// time the turn took, e.g. 「任务已完成 · 5 步 · 12 秒」.
        public var summaryLine: String {
            var parts = [PocketStrings.taskDone(), PocketStrings.steps(steps.count)]
            if let elapsed { parts.append(Self.duration(elapsed)) }
            return parts.joined(separator: " · ")
        }

        static func duration(_ t: TimeInterval) -> String {
            let s = max(1, Int(t.rounded()))
            if s < 60 { return PocketStrings.seconds(s) }
            let m = PocketStrings.minutes(s / 60)
            return s % 60 == 0 ? m : m + " " + PocketStrings.seconds(s % 60)
        }
    }

    public struct Working: Equatable, Sendable {
        /// The messages this bubble works on, oldest first; empty for a turn of room speech.
        public var messages: [String] = []
        public var phase: Phase
        public var steps: [Step] = []
        public var text = ""
        public var speechID: String?
        public var startedAt: Date?
        /// Current step for the nav subtitle and the ambient view while `tool` ("在查 · <line>").
        public var toolLabel: String? { phase == .tool ? steps.last?.line : nil }
        /// Steps before the current one, folded into "+N 步" while working.
        public var foldedSteps: Int { max(0, steps.count - 1) }
    }

    /// An answer shown before its log row arrives (`answer_final` precedes the answer's row).
    public struct Provisional: Equatable, Sendable {
        public var text: String
        public var messageIDs: [String]
        public var trace: Trace
        public var at: Date
    }

    public private(set) var working: Working?
    public private(set) var provisional: [Provisional] = []
    /// Tool steps of answered turns in this session, by `msg:<message_ids>` and by
    /// `text:<answer>`, for the collapsed step line above the final answer. Not persisted: after a
    /// relaunch an answer shows without its steps.
    public private(set) var answerTraces: [String: Trace] = [:]

    public init() {}

    /// Shows the bubble for a message before its turn frames arrive (fixtures).
    public mutating func expect(messageID: String, now: Date = Date()) {
        if var w = working {
            if !w.messages.contains(messageID) { w.messages.append(messageID) }
            working = w
            return
        }
        working = Working(messages: [messageID], phase: .received, startedAt: now)
    }

    /// Whether a frame naming `ids` is about the bubble's turn.
    private static func names(_ w: Working, _ ids: [String]) -> Bool {
        w.messages.isEmpty || ids.contains(where: w.messages.contains)
    }

    /// Ends the wait without an answer.
    public mutating func reset() { working = nil }

    /// `ready.turn` after a (re)connect: the open turn, or none. A bubble whose turn closed while
    /// the socket was down goes; an open turn the app had not seen gets one.
    @discardableResult
    public mutating func restore(_ snapshot: LiveEvent.TurnSnapshot?, now: Date = Date()) -> Bool {
        let before = working
        guard let snapshot else {
            working = nil
            return before != nil
        }
        if var w = working {
            for id in snapshot.messageIDs where !w.messages.contains(id) { w.messages.append(id) }
            working = w
        } else {
            let phase: Phase = snapshot.phase == "tool" ? .tool : snapshot.phase == "received" ? .received : .thinking
            working = Working(messages: snapshot.messageIDs, phase: phase, startedAt: nil)
        }
        return before != working
    }

    /// A message failed after it reached the brain (`brain_unreachable`): the bubble stops
    /// waiting for it, and goes when it was its only message.
    @discardableResult
    public mutating func messageFailed(_ id: String) -> Bool {
        guard var w = working, w.messages.contains(id) else { return false }
        w.messages.removeAll { $0 == id }
        working = w.messages.isEmpty ? nil : w
        return true
    }

    /// Feeds one frame. Returns true when anything visible changed.
    @discardableResult
    public mutating func handle(frame f: [String: Any], now: Date = Date()) -> Bool {
        let ids = LiveEvent.messageIDs(f)
        switch f["type"] as? String {
        case "turn":
            switch f["phase"] as? String {
            case "received":
                if var w = working {
                    for id in ids where !w.messages.contains(id) { w.messages.append(id) }
                    let changed = w != working
                    working = w
                    return changed
                }
                working = Working(messages: ids, phase: .received, startedAt: now)
                return true
            case "thinking":
                var w = working ?? Working(messages: ids, phase: .thinking, startedAt: now)
                if w.phase == .streaming { return false }
                // Steps stay open until their result frame: a thinking frame between parallel
                // calls and their results must not close them.
                w.phase = .thinking
                let changed = w != working
                working = w
                return changed
            case "tool":
                var w = working ?? Working(messages: ids, phase: .tool, startedAt: now)
                let raw = (f["label"] as? String) ?? ""
                let input = f["input_summary"] as? String
                if input == nil, raw.hasSuffix(ToolLine.resultSuffix) {
                    // The result: the oldest open call of this tool is done. A runtime that never
                    // sent the call gets its line here, as on the Feishu process card.
                    let name = Self.name(String(raw.dropLast(ToolLine.resultSuffix.count)))
                    if let i = w.steps.firstIndex(where: { !$0.done && $0.name == name }) {
                        w.steps[i].done = true
                    } else {
                        w.steps.append(Step(name: name, done: true))
                    }
                } else {
                    let name = Self.name(raw)
                    if let input {
                        // The full call fills the line its early frame opened, if any.
                        let summary = ToolLine.summarize(input)
                        if let i = w.steps.lastIndex(where: { !$0.done && !$0.hasInput && $0.name == name }) {
                            w.steps[i].summary = summary
                            w.steps[i].hasInput = true
                        } else {
                            w.steps.append(Step(name: name, summary: summary, hasInput: true))
                        }
                    } else if !w.steps.contains(where: { !$0.done && !$0.hasInput && $0.name == name }) {
                        w.steps.append(Step(name: name))
                    }
                }
                if w.phase != .streaming { w.phase = .tool }
                let changed = w != working
                working = w
                return changed
            case "idle":
                guard let w = working, Self.names(w, ids) else { return false }
                working = nil
                return true
            default:
                return false
            }
        case "duoduo_said":
            if f["kind"] as? String == "reaction" { return false }
            let chunk = f["text"] as? String ?? ""
            let id = f["speech_id"] as? String
            var w = working ?? Working(phase: .streaming, startedAt: now)
            if w.speechID != nil, w.speechID == id {
                w.text += chunk
            } else {
                w.speechID = id
                w.text = chunk
            }
            for i in w.steps.indices { w.steps[i].done = true }
            w.phase = .streaming
            working = w
            return true
        case "answer_final":
            let text = f["text"] as? String ?? ""
            // An answer naming the bubble's messages ends it; its steps are this answer's. A
            // bubble still at 「收到了」 has none. An answer to other inputs leaves the bubble
            // waiting, without the streamed text that was this answer's.
            var trace = Trace.empty
            if let w = working {
                if Self.names(w, ids) {
                    trace = Trace(steps: w.steps.map { s -> Step in var d = s; d.done = true; return d },
                                  elapsed: w.startedAt.map { now.timeIntervalSince($0) })
                    working = nil
                } else if w.speechID != nil, w.speechID == f["speech_id"] as? String {
                    var k = w
                    k.text = ""
                    k.speechID = nil
                    k.phase = .thinking
                    working = k
                }
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            provisional.append(Provisional(text: text, messageIDs: ids, trace: trace, at: now))
            return true
        default:
            return false
        }
    }

    /// Ends the working bubble when an answer row naming its messages is in the room log. The
    /// live `answer_final` can be missed: it may arrive while the socket is down.
    @discardableResult
    public mutating func endIfAnswered(in entries: [ImlogEntry]) -> Bool {
        guard let w = working, !w.messages.isEmpty,
              entries.contains(where: { $0.isAnswer && Self.names(w, $0.message_ids ?? []) }) else { return false }
        working = nil
        return true
    }

    /// Drops provisional answers whose log row has arrived (same text).
    @discardableResult
    public mutating func settle(with entries: [ImlogEntry]) -> Bool {
        guard !provisional.isEmpty else { return false }
        let answers = Set(entries.filter(\.isAnswer).map { $0.shownText.trimmingCharacters(in: .whitespacesAndNewlines) })
        let before = provisional.count
        provisional.removeAll { p in
            let key = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard answers.contains(key) else { return false }
            if !p.trace.steps.isEmpty {
                answerTraces["text:" + key] = p.trace
                if !p.messageIDs.isEmpty { answerTraces[Self.traceKey(p.messageIDs)] = p.trace }
            }
            return true
        }
        return provisional.count != before
    }

    static func traceKey(_ ids: [String]) -> String { "msg:" + ids.sorted().joined(separator: ",") }

    /// Steps of an answered turn, for the collapsed line above the final answer: by the row's
    /// `message_ids` when it has them, else by the answer text.
    public func trace(forAnswer text: String, messageIDs: [String]? = nil) -> Trace {
        if let ids = messageIDs, !ids.isEmpty, let t = answerTraces[Self.traceKey(ids)] { return t }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return answerTraces["text:" + key] ?? provisional.first { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == key }?.trace ?? .empty
    }

    private static func name(_ raw: String) -> String {
        let n = ToolLine.displayName(raw.trimmingCharacters(in: .whitespaces))
        return n.isEmpty ? "tool" : n
    }
}
