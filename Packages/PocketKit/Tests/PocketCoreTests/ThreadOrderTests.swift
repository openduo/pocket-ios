// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import XCTest
@testable import PocketCore

/// A folded turn: Passport notes 9, 10 and 11 go in while the brain works on note 7; it folds them
/// into one turn, and the answer's `message_ids` covers all of them. The channel shows that answer
/// live (`answer_final`) but does not log it in this scene (a superseded speech). Note 12
/// follows. The live answer must stay above note 12, and no 「在想」 bubble may stay behind for
/// note 11.
final class ThreadOrderTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Shanghai")!

    private func t(_ s: String) -> Date { ThreadBuilder.parse(s)! }

    private func m(_ n: Int) -> String { "00000000-0000-4000-8000-0000000000\(String(format: "%02d", n))" }

    private func typed(_ at: String, _ n: Int, _ text: String, _ source: String = "passport") -> ImlogEntry {
        ImlogEntry(at: at, kind: "typed", text: text, utt_id: m(n), voice_source: source)
    }

    private func answer(_ at: String, _ ns: [Int], _ text: String) -> ImlogEntry {
        ImlogEntry(at: at, speaker: "多多", kind: "answer", text: text, unspoken: true, message_ids: ns.map(m))
    }

    private var logThrough11: [ImlogEntry] {
        [
            typed("2030-01-01T10:10:03.998Z", 6, "只要原版的"),
            answer("2030-01-01T10:10:33.618Z", [6], "查好了，符合条件的有两家"),
            typed("2030-01-01T10:33:02.240Z", 7, "Okay.", "phone"),
            typed("2030-01-01T10:33:22.134Z", 8, "I read that article", "phone"),
            typed("2030-01-01T10:33:45.904Z", 9, "我说的是那款新相机"),
            typed("2030-01-01T10:33:56.947Z", 10, "帮我查查它的评测"),
            typed("2030-01-01T10:34:07.114Z", 11, "A B C"),
        ]
    }

    private let foldedAnswer = "查到了，评测有三篇"
    private let backups = "All three backups finished"
    private var folded: [Int] { [7, 8, 9, 10, 11] }

    /// Frames in the order the phone receives them.
    private func liveTurn() -> TurnState {
        var turn = TurnState()
        turn.handle(frame: ["type": "turn", "phase": "received", "message_ids": [m(9)]], now: t("2030-01-01T10:33:46.052Z"))
        turn.handle(frame: ["type": "turn", "phase": "received", "message_ids": [m(10)]], now: t("2030-01-01T10:33:57.094Z"))
        turn.handle(frame: ["type": "turn", "phase": "tool", "label": "WebSearch", "message_ids": []],
                    now: t("2030-01-01T10:34:03.239Z"))
        turn.handle(frame: ["type": "turn", "phase": "received", "message_ids": [m(11)]], now: t("2030-01-01T10:34:07.257Z"))
        for i in 0..<22 {
            turn.handle(frame: ["type": "turn", "phase": "tool", "label": "WebSearch",
                                "input_summary": #"{"query":"camera \#(i)"}"#, "message_ids": []])
            turn.handle(frame: ["type": "turn", "phase": "tool", "label": "WebSearch ✓", "message_ids": []])
            turn.handle(frame: ["type": "turn", "phase": "thinking", "message_ids": []])
        }
        // The answer covers every input open at its turn's first terminal, then idle for it.
        turn.handle(frame: ["type": "answer_final", "message_ids": folded.map(m), "text": foldedAnswer, "speech_id": "c-" + m(7)],
                    now: t("2030-01-01T10:40:41.000Z"))
        turn.handle(frame: ["type": "turn", "phase": "idle", "message_ids": folded.map(m)])
        return turn
    }

    private func build(_ entries: [ImlogEntry], _ turn: TurnState) -> [ThreadRow] {
        ThreadBuilder(now: t("2030-01-01T11:00:00.000Z"), timeZone: tz).build(.init(entries: entries, turn: turn))
    }

    /// Row ids without time separators, for comparing orders.
    private func ids(_ rows: [ThreadRow]) -> [String] {
        rows.compactMap { if case .separator = $0 { nil } else { $0.id } }
    }

    private func ans(_ ns: [Int]) -> String { "ans:" + ns.map(m).sorted().joined(separator: ",") }

    func testFoldedTurnAnswerEndsTheBubbleAndKeepsItsSteps() {
        let turn = liveTurn()
        XCTAssertNil(turn.working)
        XCTAssertEqual(turn.provisional.map(\.messageIDs), [folded.map(m)])
        // Every step of the turn stays with its answer; the time counts from the first delivery.
        XCTAssertEqual(turn.provisional.first?.trace.steps.count, 22)
        XCTAssertEqual(turn.provisional.first?.trace.elapsed.map { Int($0) }, 414)
    }

    func testLiveAnswerStaysAboveALaterNote() {
        var turn = liveTurn()
        var log = logThrough11
        log.append(typed("2030-01-01T10:43:45.429Z", 12, "我没让你现在就买"))
        turn.handle(frame: ["type": "turn", "phase": "received", "message_ids": [m(12)]], now: t("2030-01-01T10:43:45.808Z"))
        turn.handle(frame: ["type": "turn", "phase": "thinking", "message_ids": [m(12)]], now: t("2030-01-01T10:43:46.572Z"))
        XCTAssertEqual(ids(build(log, turn)).suffix(4),
                       ["mine:typed:" + m(11), ans(folded), "mine:typed:" + m(12), "working"])

        // Note 12 answered: the live bubble and then its log row keep one id and one place.
        turn.handle(frame: ["type": "answer_final", "message_ids": [m(12)], "text": backups, "speech_id": "c-" + m(12)],
                    now: t("2030-01-01T10:44:28.771Z"))
        let live = ids(build(log, turn))
        log.append(answer("2030-01-01T10:44:28.607Z", [12], backups))
        XCTAssertTrue(turn.settle(with: log))
        let rows = build(log, turn)
        XCTAssertEqual(ids(rows), live)
        XCTAssertEqual(ids(rows).suffix(4), ["mine:typed:" + m(11), ans(folded), "mine:typed:" + m(12), ans([12])])
        // The note-12 answer took no steps from the earlier turn.
        guard case .duoduo(let d) = rows.last else { return XCTFail("\(rows)") }
        XCTAssertTrue(d.trace.steps.isEmpty)
        XCTAssertNil(turn.working)
    }

    /// Had the channel logged the folded answer, a phone that missed every frame (rows replayed
    /// after unlocking) builds the same rows as the phone that saw them live.
    func testCatchUpBuildsTheSameOrderAsLive() {
        var live = liveTurn()
        var log = logThrough11 + [typed("2030-01-01T10:43:45.429Z", 12, "我没让你现在就买")]
        live.handle(frame: ["type": "turn", "phase": "received", "message_ids": [m(12)]], now: t("2030-01-01T10:43:45.808Z"))
        let liveIDs = ids(build(log, live))

        var caught = TurnState()
        caught.restore(.init(messageIDs: [m(12)], phase: "received"))
        log.insert(answer("2030-01-01T10:40:40.900Z", folded, foldedAnswer), at: log.count - 1)
        XCTAssertFalse(caught.endIfAnswered(in: log))
        XCTAssertEqual(ids(build(log, caught)), liveIDs)
    }

    /// An answer whose turn did not cover the bubble's message leaves the bubble; the bubble's own
    /// turn then goes on.
    func testAnAnswerToAnEarlierTurnKeepsAJustSentNote() {
        var turn = TurnState()
        turn.handle(frame: ["type": "turn", "phase": "received", "message_ids": ["u2"]])
        turn.handle(frame: ["type": "answer_final", "message_ids": ["u1"], "text": "a1"])
        XCTAssertEqual(turn.working?.messages, ["u2"])
        XCTAssertEqual(turn.provisional.first?.trace.steps, [])
        turn.handle(frame: ["type": "turn", "phase": "thinking", "message_ids": ["u2"]])
        XCTAssertEqual(turn.working?.phase, .thinking)
    }

    func testIdleOfAnEarlierTurnKeepsAJustSentNote() {
        var turn = TurnState()
        turn.handle(frame: ["type": "turn", "phase": "received", "message_ids": ["u2"]])
        turn.handle(frame: ["type": "turn", "phase": "idle", "message_ids": ["u1"]])
        XCTAssertEqual(turn.working?.phase, .received)
    }

    /// Socket lost during the folded turn: the bubble for notes 9, 10, 11 ends on the logged answer
    /// that names them; an answer naming none of them does not end it.
    func testLoggedAnswerNamingTheNotesEndsTheBubble() {
        var turn = TurnState()
        turn.restore(.init(messageIDs: [9, 10, 11].map(m), phase: "tool"))
        XCTAssertFalse(turn.endIfAnswered(in: logThrough11))
        XCTAssertFalse(turn.endIfAnswered(in: logThrough11 + [answer("2030-01-01T10:40:00.000Z", [], "房间里的回答")]))
        XCTAssertNotNil(turn.working)
        XCTAssertTrue(turn.endIfAnswered(in: logThrough11 + [answer("2030-01-01T10:40:40.900Z", folded, foldedAnswer)]))
        XCTAssertNil(turn.working)
    }

    func testStepsAreFoundByMessageIDsWhenTheLoggedTextDiffers() {
        var turn = TurnState()
        turn.handle(frame: ["type": "turn", "phase": "received", "message_ids": ["u1"]])
        turn.handle(frame: ["type": "turn", "phase": "tool", "label": "Read", "input_summary": #"{"file_path":"a"}"#])
        turn.handle(frame: ["type": "answer_final", "message_ids": ["u1"], "text": "好"])
        turn.settle(with: [ImlogEntry(at: "2030-01-01T10:00:00.000Z", speaker: "多多", kind: "answer", text: "好",
                                      message_ids: ["u1"])])
        XCTAssertEqual(turn.trace(forAnswer: "另一段文字", messageIDs: ["u1"]).steps.count, 1)
    }
}
