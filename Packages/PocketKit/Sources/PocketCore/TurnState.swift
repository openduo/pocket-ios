// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// 多多's working bubble (design §4.4), driven by display-socket frames.
///
/// - A turn starts when the app's own send is accepted (`expect`) or on `turn received` (a Passport
///   note, typed text from another screen, ambient speech).
/// - `thinking` / `tool` frames update the phase. Tool frames become steps by the Feishu process
///   card's rules (`ToolLine`): per call the channel sends `label` = name (claude's early call
///   without input), `label` + `input_summary` (the full call), and `label` = `<name> ✓` (the
///   result). The first two fill one step; the result marks the oldest open step of that name
///   done. The channel drops `tool_use_id`, so parallel calls of one tool pair up in order.
/// - `duoduo_said` deltas (not reactions) stream the answer text, folded by `speech_id`.
/// - Pocket is one conversation: the first answer after the waiting notes were sent ends the
///   bubble, whatever `utt_id` it carries. Live, that is any `answer_final` (it leaves a
///   provisional answer until its log row arrives); in the room log, the first answer row after
///   the earliest waiting note's typed row (`endIfAnswered`, `LogCorrelation`), since the live
///   frame can be missed. The brain folds notes sent while it works into the running turn and
///   answers under the first one's `utt_id`. If a note is still queued behind that answer, its
///   own turn's first `thinking` frame brings the bubble back.
/// - `idle` ends a turn that produced no answer (docs/ble-protocol.md §9): its own utterance, an unnamed one,
///   or the turn the bubble has seen work. A bubble still at 「收到了」 is kept on another
///   utterance's `idle`: that turn ended before ours started.
/// - The brain runs one turn at a time and `thinking` / `tool` frames carry no `utt_id`, so the
///   bubble shows whatever turn the brain is in.
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
        /// The latest note this bubble waits on.
        public var uttID: String?
        /// Every note this bubble waits on, oldest first; the first answer after them ends it.
        public var notes: [String] = []
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

    /// An answer shown before its log row arrives (`answer_final` precedes `imlog_append`).
    public struct Provisional: Equatable, Sendable {
        public var text: String
        public var uttID: String?
        public var trace: Trace
        public var at: Date
    }

    public private(set) var working: Working?
    public private(set) var provisional: [Provisional] = []
    /// Tool steps of answered turns in this session, by `utt:<utt_id>` and by `text:<answer>`, for
    /// the collapsed step line above the final answer. Not persisted: after a relaunch an answer
    /// shows without its steps.
    public private(set) var answerTraces: [String: Trace] = [:]

    public init() {}

    public mutating func expect(uttID: String?, now: Date = Date()) {
        if let w = working, w.uttID == uttID, uttID != nil { return }
        let notes = (working?.notes ?? []) + (uttID.map { [$0] } ?? [])
        // Sent while the brain works: the running turn goes on (and may take this note in), so
        // its steps and start stay; the bubble now waits for this note too.
        if var w = working, w.phase != .received {
            w.uttID = uttID
            w.notes = notes
            working = w
            return
        }
        working = Working(uttID: uttID, notes: notes, phase: .received, startedAt: now)
    }

    /// Whether `idle` of `utt` ends the bubble: its own utterance, an unnamed one, or the turn
    /// the bubble has been showing (see the type comment).
    private func idleEnds(_ w: Working, utt: String?) -> Bool {
        w.uttID == nil || utt == nil || w.uttID == utt || w.phase != .received
    }

    /// Ends the wait without an answer (display socket lost and restored: a missed `idle` must
    /// not leave the bubble spinning). A turn still running restores it: the channel repeats
    /// `turn thinking` every 2 s while the brain works (`bridge.turn_thinking_interval_ms`).
    public mutating func reset() { working = nil }

    /// Feeds one frame. Returns true when anything visible changed.
    @discardableResult
    public mutating func handle(frame f: [String: Any], now: Date = Date()) -> Bool {
        switch f["type"] as? String {
        case "turn":
            let utt = f["utt_id"] as? String
            switch f["phase"] as? String {
            case "received":
                if var w = working, w.uttID == nil || w.uttID == utt {
                    if w.uttID == nil, let utt { w.uttID = utt; w.notes.append(utt) }
                    working = w
                    return false
                }
                working = Working(uttID: utt, notes: (working?.notes ?? []) + (utt.map { [$0] } ?? []),
                                  phase: .received, startedAt: now)
                return true
            case "thinking":
                var w = working ?? Working(uttID: utt, notes: utt.map { [$0] } ?? [], phase: .thinking, startedAt: now)
                if w.phase == .streaming { return false }
                // Steps stay open until their result frame: a thinking frame between parallel
                // calls and their results must not close them.
                w.phase = .thinking
                let changed = w != working
                working = w
                return changed
            case "tool":
                var w = working ?? Working(uttID: utt, notes: utt.map { [$0] } ?? [], phase: .tool, startedAt: now)
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
                guard let w = working, idleEnds(w, utt: utt) else { return false }
                working = nil
                return true
            default:
                return false
            }
        case "duoduo_said":
            if f["kind"] as? String == "reaction" { return false }
            let chunk = f["text"] as? String ?? ""
            let id = f["speech_id"] as? String
            let utt = f["utt_id"] as? String
            var w = working ?? Working(uttID: utt, notes: utt.map { [$0] } ?? [], phase: .streaming, startedAt: now)
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
            let utt = f["utt_id"] as? String
            // Any answer after the waiting notes ends the bubble (see the type comment); its steps
            // are this answer's. A bubble still at 「收到了」 has none.
            var trace = Trace.empty
            if let w = working {
                trace = Trace(steps: w.steps.map { s -> Step in var d = s; d.done = true; return d },
                              elapsed: w.startedAt.map { now.timeIntervalSince($0) })
                working = nil
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            provisional.append(Provisional(text: text, uttID: utt, trace: trace, at: now))
            return true
        default:
            return false
        }
    }

    /// Ends the working bubble when an answer after its notes is in the room log. The live
    /// `answer_final` can be missed: it may arrive while the display socket is down, or before
    /// the wait was registered, and the log is the only record then. `entries` must be whole
    /// days, oldest first, so a typed row precedes the answers after it (`LogCorrelation`).
    @discardableResult
    public mutating func endIfAnswered(in entries: [ImlogEntry]) -> Bool {
        guard let notes = working?.notes,
              LogCorrelation.firstAnswerIndex(after: Set(notes), in: entries) != nil else { return false }
        working = nil
        return true
    }

    /// Drops provisional answers whose log row has arrived (same text).
    @discardableResult
    public mutating func settle(with entries: [ImlogEntry]) -> Bool {
        guard !provisional.isEmpty else { return false }
        let answers = Set(entries.filter(\.isAnswer).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) })
        let before = provisional.count
        provisional.removeAll { p in
            let key = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard answers.contains(key) else { return false }
            if !p.trace.steps.isEmpty {
                answerTraces["text:" + key] = p.trace
                if let u = p.uttID { answerTraces["utt:" + u] = p.trace }
            }
            return true
        }
        return provisional.count != before
    }

    /// Steps of an answered turn, for the collapsed line above the final answer: by the row's
    /// `utt_id` when it has one, else by the answer text.
    public func trace(forAnswer text: String, uttID: String? = nil) -> Trace {
        if let u = uttID, let t = answerTraces["utt:" + u] { return t }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return answerTraces["text:" + key] ?? provisional.first { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == key }?.trace ?? .empty
    }

    private static func name(_ raw: String) -> String {
        let n = ToolLine.displayName(raw.trimmingCharacters(in: .whitespaces))
        return n.isEmpty ? "tool" : n
    }
}
