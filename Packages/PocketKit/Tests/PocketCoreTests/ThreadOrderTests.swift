// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import XCTest
@testable import PocketCore

/// A folded turn: Passport notes 9, 10 and 11 go in while the brain works; it folds them into one
/// turn and answers under note 7's `utt_id`, an answer the channel shows live (`answer_final`)
/// but does not log (a superseded speech). Note 12 follows. The live answer must stay above note
/// 12, and no 「在想」 bubble may stay behind for note 11.
final class ThreadOrderTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Shanghai")!

    private func t(_ s: String) -> Date { ThreadBuilder.parse(s)! }

    private func typed(_ at: String, _ n: Int, _ text: String, _ source: String = "passport") -> ImlogEntry {
        ImlogEntry(at: at, kind: "typed", text: text, utt_id: "inj-1700000000000-5151-\(n)", voice_source: source)
    }

    private func answer(_ at: String, _ n: Int?, _ text: String) -> ImlogEntry {
        ImlogEntry(at: at, speaker: "多多", kind: "answer", text: text, utt_id: n.map { "inj-1700000000000-5151-\($0)" },
                   unspoken: true)
    }

    private func utt(_ n: Int) -> String { "inj-1700000000000-5151-\(n)" }

    private var logThrough11: [ImlogEntry] {
        [
            typed("2030-01-01T10:10:03.998Z", 6, "只要原版的"),
            answer("2030-01-01T10:10:33.618Z", 6, "查好了，符合条件的有两家"),
            typed("2030-01-01T10:33:02.240Z", 7, "Okay.", "phone"),
            typed("2030-01-01T10:33:22.134Z", 8, "I read that article", "phone"),
            typed("2030-01-01T10:33:45.904Z", 9, "我说的是那款新相机"),
            typed("2030-01-01T10:33:56.947Z", 10, "帮我查查它的评测"),
            typed("2030-01-01T10:34:07.114Z", 11, "A B C"),
        ]
    }

    private let foldedAnswer = "查到了，评测有三篇"
    private let backups = "All three backups finished"

    /// Frames in the order the phone receives them.
    private func liveTurn() -> TurnState {
        var turn = TurnState()
        turn.expect(uttID: utt(9), now: t("2030-01-01T10:33:46.052Z"))
        turn.expect(uttID: utt(10), now: t("2030-01-01T10:33:57.094Z"))
        turn.handle(frame: ["type": "turn", "utt_id": NSNull(), "phase": "tool", "label": "WebSearch"],
                    now: t("2030-01-01T10:34:03.239Z"))
        turn.expect(uttID: utt(11), now: t("2030-01-01T10:34:07.257Z"))
        for i in 0..<22 {
            turn.handle(frame: ["type": "turn", "utt_id": NSNull(), "phase": "tool", "label": "WebSearch",
                                "input_summary": #"{"query":"camera \#(i)"}"#])
            turn.handle(frame: ["type": "turn", "utt_id": NSNull(), "phase": "tool", "label": "WebSearch ✓"])
            turn.handle(frame: ["type": "turn", "utt_id": NSNull(), "phase": "thinking"])
        }
        // The answer names the first note of the folded turn, then idle for it.
        turn.handle(frame: ["type": "answer_final", "utt_id": utt(7), "text": foldedAnswer, "speech_id": "ch:" + utt(7)],
                    now: t("2030-01-01T10:40:41.000Z"))
        turn.handle(frame: ["type": "turn", "utt_id": utt(7), "phase": "idle"])
        return turn
    }

    private func build(_ entries: [ImlogEntry], _ turn: TurnState) -> [ThreadRow] {
        ThreadBuilder(now: t("2030-01-01T11:00:00.000Z"), timeZone: tz).build(.init(entries: entries, turn: turn))
    }

    /// Row ids without time separators, for comparing orders.
    private func ids(_ rows: [ThreadRow]) -> [String] {
        rows.compactMap { if case .separator = $0 { nil } else { $0.id } }
    }

    func testFoldedTurnAnswerEndsTheBubbleAndKeepsItsSteps() {
        let turn = liveTurn()
        // No stale 「在想」 for note 11: the turn the bubble showed has answered.
        XCTAssertNil(turn.working)
        XCTAssertEqual(turn.provisional.map(\.uttID), [utt(7)])
        // Steps from before note 11 was sent stay with the turn (all 22); the time counts from
        // note 10, the last note sent before the brain worked.
        XCTAssertEqual(turn.provisional.first?.trace.steps.count, 22)
        XCTAssertEqual(turn.provisional.first?.trace.elapsed.map { Int($0) }, 403)
    }

    func testLiveAnswerStaysAboveALaterNote() {
        var turn = liveTurn()
        var log = logThrough11
        log.append(typed("2030-01-01T10:43:45.429Z", 12, "我没让你现在就买"))
        turn.expect(uttID: utt(12), now: t("2030-01-01T10:43:45.808Z"))
        turn.handle(frame: ["type": "turn", "utt_id": NSNull(), "phase": "thinking"], now: t("2030-01-01T10:43:46.572Z"))
        XCTAssertEqual(ids(build(log, turn)).suffix(4),
                       ["mine:typed:" + utt(11), "ans:" + utt(7), "mine:typed:" + utt(12), "working"])

        // Note 12 answered: the live bubble and then its log row keep one id and one place.
        turn.handle(frame: ["type": "answer_final", "utt_id": utt(12), "text": backups, "speech_id": "ch:" + utt(12)],
                    now: t("2030-01-01T10:44:28.771Z"))
        let live = ids(build(log, turn))
        log.append(answer("2030-01-01T10:44:28.607Z", 12, backups))
        XCTAssertTrue(turn.settle(with: log))
        let rows = build(log, turn)
        XCTAssertEqual(ids(rows), live)
        XCTAssertEqual(ids(rows).suffix(4),
                       ["mine:typed:" + utt(11), "ans:" + utt(7), "mine:typed:" + utt(12), "ans:" + utt(12)])
        // The note-12 answer took no steps from the earlier turn.
        guard case .duoduo(let d) = rows.last else { return XCTFail("\(rows)") }
        XCTAssertTrue(d.trace.steps.isEmpty)
        XCTAssertNil(turn.working)
    }

    /// Had the channel logged the note-7 answer, a phone that missed every frame (catch-up from
    /// `/api/state` after unlocking) builds the same rows as the phone that saw them live.
    func testCatchUpBuildsTheSameOrderAsLive() {
        var live = liveTurn()
        var log = logThrough11 + [typed("2030-01-01T10:43:45.429Z", 12, "我没让你现在就买")]
        live.expect(uttID: utt(12), now: t("2030-01-01T10:43:45.808Z"))
        let liveIDs = ids(build(log, live))

        var caught = TurnState()
        caught.expect(uttID: utt(12))
        log.insert(answer("2030-01-01T10:40:40.900Z", 7, foldedAnswer), at: log.count - 1)
        XCTAssertFalse(caught.endIfAnswered(in: log))
        XCTAssertEqual(ids(build(log, caught)), liveIDs)
    }

    func testFirstLoggedAnswerAfterTheNoteIsOursWhateverItNames() {
        let log = [
            answer("2030-01-01T10:43:40.000Z", 11, "before note 12 was sent"),
            typed("2030-01-01T10:43:45.429Z", 12, "x"),
            answer("2030-01-01T10:43:50.000Z", 11, "late answer to note 11"),
            answer("2030-01-01T10:44:28.607Z", 12, backups),
        ]
        XCTAssertEqual(LogCorrelation.firstAnswerIndex(after: [utt(12)], in: log), 2)
        XCTAssertNil(LogCorrelation.firstAnswerIndex(after: [utt(12)], in: Array(log.prefix(2))))
        // A row without utt_id after the note counts too (a proactive message).
        XCTAssertEqual(LogCorrelation.firstAnswerIndex(after: [utt(12)], in: [log[1], answer("2030-01-01T10:44:00.000Z", nil, "y")]), 1)
        // An answer naming the note counts when its typed row is on the previous day.
        XCTAssertEqual(LogCorrelation.firstAnswerIndex(after: [utt(12)], in: [log[3]]), 0)
        // Several notes: the earliest one's row starts the search.
        XCTAssertEqual(LogCorrelation.firstAnswerIndex(after: [utt(12), utt(13)], in: log + [typed("2030-01-01T10:45:00.000Z", 13, "y")]), 2)
        XCTAssertNil(LogCorrelation.firstAnswerIndex(after: [], in: log))
    }

    /// The first answer after the note ends the bubble even before the bubble saw the turn work;
    /// a note still queued behind it gets the bubble back on its turn's first frame.
    func testAnswerAfterAJustSentNoteEndsTheBubble() {
        var turn = TurnState()
        turn.expect(uttID: "u2")
        turn.handle(frame: ["type": "answer_final", "utt_id": "u1", "text": "a1"])
        XCTAssertNil(turn.working)
        XCTAssertEqual(turn.provisional.first?.trace.steps, [])
        turn.handle(frame: ["type": "turn", "utt_id": NSNull(), "phase": "thinking"])
        XCTAssertEqual(turn.working?.phase, .thinking)
    }

    func testIdleOfAnEarlierTurnKeepsAJustSentNote() {
        var turn = TurnState()
        turn.expect(uttID: "u2")
        turn.handle(frame: ["type": "turn", "utt_id": "u1", "phase": "idle"])
        XCTAssertEqual(turn.working?.phase, .received)
    }

    /// Socket lost during the folded turn: the bubble for notes 9, 10, 11 ends on the first answer
    /// logged after note 9, whatever it names; an answer logged before it does not end it.
    func testLoggedAnswerAfterBatchedNotesEndsTheBubble() {
        var turn = TurnState()
        for n in [9, 10, 11] { turn.expect(uttID: utt(n)) }
        XCTAssertEqual(turn.working?.notes, [utt(9), utt(10), utt(11)])
        XCTAssertFalse(turn.endIfAnswered(in: logThrough11))
        XCTAssertNotNil(turn.working)
        XCTAssertTrue(turn.endIfAnswered(in: logThrough11 + [answer("2030-01-01T10:40:40.900Z", nil, foldedAnswer)]))
        XCTAssertNil(turn.working)
    }

    func testStepsAreFoundByUttIDWhenTheLoggedTextDiffers() {
        var turn = TurnState()
        turn.expect(uttID: "u1")
        turn.handle(frame: ["type": "turn", "phase": "tool", "label": "Read", "input_summary": #"{"file_path":"a"}"#])
        turn.handle(frame: ["type": "answer_final", "utt_id": "u1", "text": "好"])
        turn.settle(with: [ImlogEntry(at: "2030-01-01T10:00:00.000Z", speaker: "多多", kind: "answer", text: "好", utt_id: "u1")])
        XCTAssertEqual(turn.trace(forAnswer: "另一段文字", uttID: "u1").steps.count, 1)
    }
}
