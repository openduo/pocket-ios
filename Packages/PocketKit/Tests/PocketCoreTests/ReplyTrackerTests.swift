// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import XCTest
@testable import PocketCore

final class ReplyTrackerTests: XCTestCase {
    func testDeltasFoldIntoFullTextUnderOneReplyID() {
        var t = ReplyTracker()
        let a = t.handle(frame: ["type": "duoduo_said", "speech_id": "c-1", "text": "明天"])
        let b = t.handle(frame: ["type": "duoduo_said", "speech_id": "c-1", "text": "会下雨"])
        guard case .reply(let id1, false, "明天") = a.first, case .reply(let id2, false, "明天会下雨") = b.first else {
            return XCTFail("\(a) \(b)")
        }
        XCTAssertEqual(id1, id2)
        // The final answer replaces the partial text under the same id, then REPLY_DONE.
        let f = t.handle(frame: ["type": "answer_final", "speech_id": "c-1", "utt_id": "u1", "text": "明天会下雨，带伞。"])
        XCTAssertEqual(f, [.reply(replyID: id1, final: true, text: "明天会下雨，带伞。"), .replyDone(replyID: id1)])
    }

    func testNewSpeechStartsNewReply() {
        var t = ReplyTracker()
        let a = t.handle(frame: ["type": "duoduo_said", "speech_id": "c-1", "text": "一"])
        let b = t.handle(frame: ["type": "duoduo_said", "speech_id": "c-2", "text": "二"])
        guard case .reply(let i1, _, _) = a.first, case .reply(let i2, _, let text) = b.first else { return XCTFail() }
        XCTAssertNotEqual(i1, i2)
        XCTAssertEqual(text, "二")
    }

    func testReactionsAndEmptyAnswersAreSkipped() {
        var t = ReplyTracker()
        XCTAssertEqual(t.handle(frame: ["type": "duoduo_said", "speech_id": "s9", "kind": "reaction", "text": "嗯"]), [])
        XCTAssertEqual(t.handle(frame: ["type": "answer_final", "speech_id": "c-3", "text": "  "]), [])
        XCTAssertEqual(t.handle(frame: ["type": "transcript", "row": [:]]), [])
    }

    func testCatchUpDeliversLatestAnswerOnce() {
        var t = ReplyTracker()
        let log: [[String: Any]] = [
            ["kind": "human", "text": "你好", "at": "2026-10-07T10:00:00Z"],
            ["kind": "answer", "text": "旧回答", "at": "2026-10-07T10:00:01Z"],
            ["kind": "typed", "text": "问题", "at": "2026-10-07T10:01:00Z"],
            ["speaker": "多多", "text": "新回答", "at": "2026-10-07T10:01:05Z"],
        ]
        let out = t.catchUp(entries: log)
        guard case .reply(let id, true, "新回答") = out.first else { return XCTFail("\(out)") }
        XCTAssertEqual(out.last, .replyDone(replyID: id))
        XCTAssertEqual(t.catchUp(entries: log), [])
    }

    func testCatchUpSkipsARowOfFilesWithoutText() {
        var t = ReplyTracker()
        let log: [[String: Any]] = [
            ["speaker": "多多", "kind": "answer", "text": "发了", "at": "2026-10-07T12:34:27Z"],
            ["speaker": "多多", "kind": "answer", "text": "", "at": "2026-10-07T12:34:28Z",
             "attachments": [["name": "a.png", "mime": "image/png"]]],
        ]
        guard case .reply(_, true, "发了") = t.catchUp(entries: log).first else { return XCTFail() }
    }

    func testAnswerSeenLiveIsNotResentFromTheLog() {
        var t = ReplyTracker()
        XCTAssertEqual(t.handle(frame: ["type": "answer_final", "speech_id": "c-7", "text": "好的"]).count, 2)
        XCTAssertEqual(t.catchUp(entries: [["kind": "answer", "text": "好的\n", "at": "x"]]), [])
    }

    /// A reinstall empties the memory; the time floor keeps the new ids above the old ones.
    func testReplyIDsStayUniqueAcrossAReinstall() {
        var t = ReplyTracker()
        t.clock = { 1_800_000_000 }
        var old: [UInt32] = []
        for text in ["一", "二", "三"] {
            guard case .reply(let id, true, _) = t.handle(frame: ["type": "answer_final", "text": text]).first else { return XCTFail() }
            old.append(id)
        }
        XCTAssertEqual(old, [1_800_000_000, 1_800_000_001, 1_800_000_002])
        var fresh = ReplyTracker()
        fresh.clock = { 1_800_000_060 }
        guard case .reply(let id, true, _) = fresh.handle(frame: ["type": "answer_final", "text": "四"]).first else { return XCTFail() }
        XCTAssertGreaterThan(id, old.max()!)
    }

    func testDeliveredSurvivesRelaunch() {
        var t = ReplyTracker()
        t.clock = { 0 }
        _ = t.handle(frame: ["type": "answer_final", "speech_id": "c-7", "text": "好的"])
        var u = ReplyTracker()
        u.clock = { 0 }
        u.memory = t.memory
        XCTAssertEqual(u.catchUp(entries: [["kind": "answer", "text": "好的"]]), [])
        // Ids keep growing after a relaunch.
        guard case .reply(let id, true, _) = u.handle(frame: ["type": "answer_final", "text": "新的"]).first else { return XCTFail() }
        XCTAssertEqual(id, t.memory.lastReplyID + 1)
    }

    func testCatchUpSkipsReactionFillers() {
        var t = ReplyTracker()
        t.clock = { 0 }
        _ = t.expect(uttID: "n1")
        let filler: [String: Any] = ["kind": "reaction", "speaker": "多多", "text": "我看看", "at": "2030-01-01T09:00:02Z"]
        let typed: [String: Any] = ["kind": "typed", "text": "明天几点出发", "utt_id": "n1", "at": "2030-01-01T09:00:01Z"]
        XCTAssertEqual(t.catchUp(entries: [typed, filler]), [])
        let answer: [String: Any] = ["kind": "answer", "speaker": "多多", "text": "八点出发", "at": "2030-01-01T09:00:05Z"]
        guard case .reply(_, true, "八点出发") = t.catchUp(entries: [typed, filler, answer]).first else {
            return XCTFail("the answer after the filler is the reply")
        }
        var idle = ReplyTracker()
        idle.clock = { 0 }
        XCTAssertEqual(idle.catchUp(entries: [filler]), [])
    }

    func testReplyIDsGrowByOneAndPartialsShareTheFinalsID() {
        var t = ReplyTracker()
        t.clock = { 0 }
        var ids: [UInt32] = []
        for (i, text) in ["一", "二", "三"].enumerated() {
            guard case .reply(let id, true, text) = t.handle(frame: ["type": "answer_final", "speech_id": "c-\(i)",
                                                                      "text": text]).first else { return XCTFail() }
            ids.append(id)
        }
        XCTAssertEqual(ids, [1, 2, 3])
        guard case .reply(let p, false, _) = t.handle(frame: ["type": "duoduo_said", "speech_id": "c-9", "text": "四"]).first,
              case .reply(let f, true, _) = t.handle(frame: ["type": "answer_final", "speech_id": "c-9", "text": "四。"]).first
        else { return XCTFail() }
        XCTAssertEqual(p, 4)
        XCTAssertEqual(f, 4)
        // Wraps past 0, never sending it.
        var w = ReplyTracker()
        w.clock = { 0 }
        w.memory.lastReplyID = .max
        guard case .reply(let z, true, _) = w.handle(frame: ["type": "answer_final", "text": "x"]).first else { return XCTFail() }
        XCTAssertEqual(z, 1)
    }

    func testFirstAnswerAfterTheNoteIsTheReplyWhateverItsUttID() {
        var t = ReplyTracker()
        t.expect(uttID: "u2")
        XCTAssertTrue(t.awaiting)
        // Partials are not forwarded while a note waits: they may belong to an earlier answer.
        XCTAssertEqual(t.handle(frame: ["type": "duoduo_said", "speech_id": "c-u1", "text": "别的"]), [])
        let out = t.handle(frame: ["type": "answer_final", "utt_id": "u1", "speech_id": "c-u1", "text": "合并的回答"])
        guard case .reply(let id, true, "合并的回答") = out.first else { return XCTFail("\(out)") }
        XCTAssertEqual(out.last, .replyDone(replyID: id))
        XCTAssertFalse(t.awaiting)
    }

    func testExpectedAnswerWithRepeatedTextIsStillDelivered() {
        var t = ReplyTracker()
        _ = t.handle(frame: ["type": "answer_final", "utt_id": "u1", "text": "好的"])
        t.expect(uttID: "u2")
        XCTAssertEqual(t.handle(frame: ["type": "answer_final", "utt_id": "u2", "text": "好的"]).count, 2)
        XCTAssertFalse(t.awaiting)
    }

    func testWithoutUttIDTheNextAnswerIsTheReply() {
        var t = ReplyTracker()
        t.expect(uttID: nil)
        XCTAssertEqual(t.handle(frame: ["type": "answer_final", "utt_id": "zz", "text": "下一条"]).count, 2)
        XCTAssertFalse(t.awaiting)
    }

    func testCatchUpMatchesExpectedUtterance() {
        var t = ReplyTracker()
        t.expect(uttID: "u9")
        let log: [[String: Any]] = [
            ["kind": "answer", "utt_id": "u9", "text": "对的回答", "at": "1"],
            ["kind": "answer", "utt_id": "u8", "text": "更晚的别的回答", "at": "2"],
        ]
        guard case .reply(_, true, "对的回答") = t.catchUp(entries: log).first else { return XCTFail() }
        XCTAssertFalse(t.awaiting)
        var u = ReplyTracker()
        u.expect(uttID: "u10")
        XCTAssertEqual(u.catchUp(entries: log), [])
        XCTAssertTrue(u.awaiting)
    }

    /// Rows in the channel's shape: `utt_id` on the typed row only.
    private let roomLog: [[String: Any]] = [
        ["at": "2030-01-01T09:00:00.000Z", "speaker": NSNull(), "kind": "typed", "text": "明天有什么安排",
         "utt_id": "inj-1700000000000-4242-8", "voice_source": "passport"],
        ["at": "2030-01-01T09:00:20.000Z", "speaker": "多多", "kind": "answer", "text": "明天上午有两个会", "unspoken": true],
        ["at": "2030-01-01T09:02:30.000Z", "speaker": NSNull(), "kind": "typed", "text": "出门要带什么？",
         "utt_id": "inj-1700000000000-4242-9", "voice_source": "passport"],
        ["at": "2030-01-01T09:02:33.000Z", "speaker": "多多", "kind": "answer",
         "text": "记得带伞和充电器", "unspoken": true],
    ]

    /// The answer was logged while the display socket was down, so no `answer_final` reached the
    /// phone. The catch-up must deliver the row even though it carries no `utt_id`.
    func testAnswerLoggedWhileSocketWasDownIsDeliveredByCatchUp() {
        var t = ReplyTracker()
        _ = t.handle(frame: ["type": "answer_final", "utt_id": "inj-1700000000000-4242-8",
                             "speech_id": "c-inj-1700000000000-4242-8", "text": "明天上午有两个会"])
        XCTAssertEqual(t.expect(uttID: "inj-1700000000000-4242-9"), [.work(phase: .received, label: "")])
        let out = t.catchUp(entries: roomLog)
        guard case .reply(let id, true, "记得带伞和充电器") = out.first else {
            return XCTFail("\(out)")
        }
        XCTAssertEqual(out.last, .replyDone(replyID: id))
        XCTAssertFalse(t.awaiting)
        // Later catch-ups (every KEEPALIVE) do not resend it, and no WORK follows the reply.
        XCTAssertEqual(t.catchUp(entries: roomLog), [])
        XCTAssertEqual(t.handle(frame: ["type": "turn", "utt_id": NSNull(), "phase": "thinking"]), [])
    }

    func testCatchUpWaitsWhileTheAnswerIsNotLoggedYet() {
        var t = ReplyTracker()
        t.expect(uttID: "inj-1700000000000-4242-9")
        // The previous answer precedes the typed row: it is not this utterance's reply.
        XCTAssertEqual(t.catchUp(entries: Array(roomLog.prefix(3))), [])
        XCTAssertTrue(t.awaiting)
    }

    func testCatchUpSkipsAFilesRowAfterTheTypedRow() {
        var t = ReplyTracker()
        t.expect(uttID: "u1")
        let log: [[String: Any]] = [
            ["kind": "typed", "text": "发张图", "utt_id": "u1", "at": "1"],
            ["speaker": "多多", "kind": "answer", "text": "", "at": "2", "attachments": [["name": "a.png"]]],
            ["speaker": "多多", "kind": "answer", "text": "图发了", "at": "3"],
            ["speaker": "多多", "kind": "answer", "text": "更晚的", "at": "4"],
        ]
        guard case .reply(_, true, "图发了") = t.catchUp(entries: log).first else { return XCTFail() }
    }

    // MARK: work status (docs/ble-protocol.md §9)

    func testWaitStartSendsWorkReceived() {
        var t = ReplyTracker()
        XCTAssertEqual(t.expect(uttID: "u1"), [.work(phase: .received, label: "")])
    }

    func testTurnFramesBecomeWorkOnlyWhileWaiting() {
        var t = ReplyTracker()
        XCTAssertEqual(t.handle(frame: ["type": "turn", "utt_id": NSNull(), "phase": "thinking"]), [])
        t.expect(uttID: "u1")
        XCTAssertEqual(t.handle(frame: ["type": "turn", "utt_id": NSNull(), "phase": "thinking"]),
                       [.work(phase: .thinking, label: "")])
        // The tool label is not forwarded in v1.
        XCTAssertEqual(t.handle(frame: ["type": "turn", "phase": "tool", "label": "web_search"]),
                       [.work(phase: .tool, label: "")])
        for phase in ["received", "speaking", "done", "later"] {
            XCTAssertEqual(t.handle(frame: ["type": "turn", "phase": phase]), [], phase)
        }
        XCTAssertTrue(t.awaiting)
    }

    func testAnswerEndsTheWaitAndALaterIdleIsIgnored() {
        var t = ReplyTracker()
        t.expect(uttID: "u1")
        _ = t.handle(frame: ["type": "turn", "phase": "thinking"])
        let out = t.handle(frame: ["type": "answer_final", "utt_id": "u1", "speech_id": "c-1", "text": "好的"])
        XCTAssertEqual(out.count, 2)
        guard case .replyDone(let id) = out.last else { return XCTFail("\(out)") }
        XCTAssertNotEqual(id, PocketConstants.noReplyID)
        XCTAssertFalse(t.awaiting)
        XCTAssertEqual(t.handle(frame: ["type": "turn", "phase": "idle"]), [])
    }

    func testIdleWithoutAnswerEndsTheWaitWithReplyDoneZero() {
        var t = ReplyTracker()
        t.expect(uttID: "u1")
        XCTAssertEqual(t.handle(frame: ["type": "turn", "utt_id": NSNull(), "phase": "thinking"]),
                       [.work(phase: .thinking, label: "")])
        // A log with the note and no answer after it does not end the wait.
        XCTAssertEqual(t.catchUp(entries: [["kind": "answer", "text": "旧的", "at": "1"],
                                           ["kind": "typed", "text": "问", "utt_id": "u1", "at": "2"]]), [])
        XCTAssertEqual(t.handle(frame: ["type": "turn", "utt_id": NSNull(), "phase": "idle"]),
                       [.work(phase: .idle, label: ""), .replyDone(replyID: PocketConstants.noReplyID)])
        XCTAssertFalse(t.awaiting)
        // A late answer still goes out as a reply.
        let late = t.handle(frame: ["type": "answer_final", "utt_id": "u1", "speech_id": "c-9", "text": "晚到的回答"])
        guard case .reply(_, true, "晚到的回答") = late.first else { return XCTFail("\(late)") }
    }

    // MARK: one conversation: notes folded into the running turn

    private func u(_ n: Int) -> String { "inj-1700000000000-5151-\(n)" }

    private var batchLog: [[String: Any]] {
        [
            ["at": "2030-01-01T10:00:02.000Z", "kind": "typed", "text": "Okay.", "utt_id": u(7), "voice_source": "phone"],
            ["at": "2030-01-01T10:00:45.000Z", "kind": "typed", "text": "我说的是那款新相机", "utt_id": u(9),
             "voice_source": "passport"],
            ["at": "2030-01-01T10:00:56.000Z", "kind": "typed", "text": "帮我查查它的评测", "utt_id": u(10),
             "voice_source": "passport"],
            ["at": "2030-01-01T10:01:07.000Z", "kind": "typed", "text": "A B C", "utt_id": u(11),
             "voice_source": "passport"],
        ]
    }

    private let foldedAnswer = "查到了，评测有三篇"

    /// Notes 9, 10 and 11 go in while the brain works; it answers all of them under note 7's id.
    /// Each press ends the previous wait, so the wait is on 11 when the answer named 7 arrives;
    /// it must still end the wait (not with REPLY_DONE 0 on idle).
    func testBatchedNotesAnsweredUnderAnEarlierIDEndTheWait() {
        var t = ReplyTracker()
        for n in [9, 10, 11] {
            t.stopExpecting() // PRESS_START of the next press
            XCTAssertEqual(t.expect(uttID: u(n)), [.work(phase: .received, label: "")])
        }
        XCTAssertEqual(t.handle(frame: ["type": "turn", "utt_id": NSNull(), "phase": "tool", "label": "WebSearch"]),
                       [.work(phase: .tool, label: "")])
        let out = t.handle(frame: ["type": "answer_final", "utt_id": u(7), "speech_id": "ch:" + u(7), "text": foldedAnswer])
        guard case .reply(let id, true, foldedAnswer) = out.first else { return XCTFail("\(out)") }
        XCTAssertEqual(out, [.reply(replyID: id, final: true, text: foldedAnswer), .replyDone(replyID: id)])
        XCTAssertFalse(t.awaiting)
        // No WORK after the reply, no REPLY_DONE 0 on the idle that follows.
        XCTAssertEqual(t.handle(frame: ["type": "turn", "utt_id": u(7), "phase": "idle"]), [])
        XCTAssertEqual(t.handle(frame: ["type": "turn", "utt_id": NSNull(), "phase": "thinking"]), [])
        // The log row of the same answer is not sent again.
        XCTAssertEqual(t.catchUp(entries: batchLog + [["at": "2030-01-01T10:07:40.000Z", "speaker": "多多", "kind": "answer",
                                                     "text": foldedAnswer]]), [])
    }

    /// Several notes waiting at once: the answer after the earliest of them ends every wait.
    func testOneAnswerEndsEveryWaitingNote() {
        var t = ReplyTracker()
        t.expect(uttID: u(9))
        t.expect(uttID: u(10))
        XCTAssertEqual(t.waiting, [u(9), u(10)])
        let log = Array(batchLog.prefix(2)) + [["at": "2030-01-01T10:00:50.000Z", "kind": "answer", "text": "先回一句"]]
            + [batchLog[2]]
        guard case .reply(_, true, "先回一句") = t.catchUp(entries: log).first else { return XCTFail() }
        XCTAssertNil(t.waiting)
    }

    /// The display socket was down when the answer came: the log delivers it, under whatever
    /// `utt_id` the row names (none, or the earlier note's).
    func testAnswerUnderAnEarlierIDArrivesThroughCatchUpAfterSocketLoss() {
        for named in [nil, u(7)] as [String?] {
            var t = ReplyTracker()
            t.expect(uttID: u(11))
            XCTAssertEqual(t.catchUp(entries: batchLog), [])
            var row: [String: Any] = ["at": "2030-01-01T10:07:40.000Z", "speaker": "多多", "kind": "answer", "text": foldedAnswer]
            if let named { row["utt_id"] = named }
            let out = t.catchUp(entries: batchLog + [row])
            guard case .reply(let id, true, foldedAnswer) = out.first else { return XCTFail("\(String(describing: named)) \(out)") }
            XCTAssertEqual(out.last, .replyDone(replyID: id))
            XCTAssertFalse(t.awaiting)
            XCTAssertEqual(t.catchUp(entries: batchLog + [row]), [])
        }
    }

    /// An answer that arrived before the note was sent is never its reply, live or logged.
    func testAnAnswerFromBeforeTheNoteNeverCounts() {
        var t = ReplyTracker()
        let old = "更早的回答"
        // Live before the note: forwarded as an answer with nobody waiting.
        XCTAssertEqual(t.handle(frame: ["type": "answer_final", "utt_id": u(7), "text": old]).count, 2)
        t.expect(uttID: u(11))
        let log = Array(batchLog.prefix(1)) + [["at": "2030-01-01T10:00:10.000Z", "speaker": "多多", "kind": "answer",
                                               "text": old]] + Array(batchLog.dropFirst())
        XCTAssertEqual(t.catchUp(entries: log), [])
        // Not even an unsent one.
        var fresh = ReplyTracker()
        fresh.expect(uttID: u(11))
        XCTAssertEqual(fresh.catchUp(entries: log), [])
        XCTAssertTrue(fresh.awaiting)
        XCTAssertEqual(fresh.handle(frame: ["type": "turn", "utt_id": NSNull(), "phase": "idle"]),
                       [.work(phase: .idle, label: ""), .replyDone(replyID: PocketConstants.noReplyID)])
    }

    /// An answer sent while nobody waited (between PRESS_START and the note's RESULT) is the
    /// reply the later wait needs: it goes again under its first id, so the device stores one.
    func testRepeatClosesTheWaitUnderItsFirstID() {
        var t = ReplyTracker()
        guard case .reply(let first, true, foldedAnswer) = t.handle(frame: ["type": "answer_final", "utt_id": u(7), "text": foldedAnswer]).first
        else { return XCTFail() }
        t.expect(uttID: u(11))
        let out = t.catchUp(entries: batchLog + [["at": "2030-01-01T10:07:40.000Z", "kind": "answer", "text": foldedAnswer]])
        XCTAssertEqual(out, [.reply(replyID: first, final: true, text: foldedAnswer), .replyDone(replyID: first)])
        XCTAssertEqual(t.memory.lastReplyID, first)
        XCTAssertEqual(t.memory.delivered.filter { $0.replyID == first }.count, 1)
    }

    func testReplyIDIsStableAndNeverZero() {
        XCTAssertEqual(ReplyTracker.replyID("speech:c-1"), ReplyTracker.replyID("speech:c-1"))
        XCTAssertNotEqual(ReplyTracker.replyID("speech:c-1"), ReplyTracker.replyID("speech:c-2"))
        XCTAssertEqual(ReplyTracker.replyID(""), 0x811c9dc5)
    }

    /// Proactive answers (ble-protocol §9): an answer with no press pending is forwarded; one that
    /// came while the link was down is sent when the link comes up, once; one the device was
    /// handed is not repeated on reconnect.
    func testAnswerForNewLinkOnlyWhenTheDeviceMissedIt() {
        var t = ReplyTracker()
        guard case .reply(let a, true, "早上好") = t.handle(frame: ["type": "answer_final", "text": "早上好"]).first
        else { return XCTFail() }
        // Link down when it arrived: the link-up replay has it.
        XCTAssertEqual(t.answerForNewLink?.replyID, a)
        t.handedToLink(replyID: a)
        XCTAssertNil(t.answerForNewLink)
        // The same answer in the log is not sent again.
        XCTAssertEqual(t.catchUp(entries: [["speaker": "多多", "kind": "answer", "text": "早上好"]]), [])
        // A newer answer from background refresh while the link is down.
        guard case .reply(let b, true, "提醒你开会") = t.catchUp(entries: [["speaker": "多多", "kind": "answer", "text": "早上好"],
                                                                     ["speaker": "多多", "kind": "answer", "text": "提醒你开会"]]).first
        else { return XCTFail() }
        XCTAssertGreaterThan(b, a)
        XCTAssertEqual(t.answerForNewLink?.text, "提醒你开会")
    }

    /// The newest answer and the device's last id survive a relaunch; memories from older
    /// builds (without those fields) still decode.
    func testMemoryRoundTripAndOldFormat() throws {
        var t = ReplyTracker()
        _ = t.handle(frame: ["type": "answer_final", "text": "一"])
        let data = try JSONEncoder().encode(t.memory)
        var u = ReplyTracker()
        u.memory = try JSONDecoder().decode(ReplyTracker.Memory.self, from: data)
        XCTAssertEqual(u.answerForNewLink?.text, "一")
        let old = Data(#"{"delivered":[{"text":1,"replyID":3}],"lastReplyID":3}"#.utf8)
        let m = try JSONDecoder().decode(ReplyTracker.Memory.self, from: old)
        XCTAssertEqual(m.lastReplyID, 3)
        XCTAssertNil(m.lastAnswer)
        XCTAssertNil(m.linkedReplyID)
    }
}
