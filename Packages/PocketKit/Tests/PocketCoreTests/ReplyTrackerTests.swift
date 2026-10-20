// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import XCTest
@testable import PocketCore

final class ReplyTrackerTests: XCTestCase {
    private func answer(_ text: String, ids: [String] = [], at: String = "2030-01-01T09:00:00Z") -> ImlogEntry {
        ImlogEntry(at: at, speaker: "多多", kind: "answer", text: text, message_ids: ids)
    }

    private func final(_ text: String, ids: [String] = [], speech: String? = nil) -> [String: Any] {
        var f: [String: Any] = ["type": "answer_final", "text": text, "message_ids": ids]
        if let speech { f["speech_id"] = speech }
        return f
    }

    func testDeltasFoldIntoFullTextUnderOneReplyID() {
        var t = ReplyTracker()
        let a = t.handle(frame: ["type": "duoduo_said", "speech_id": "c-1", "text": "明天"])
        let b = t.handle(frame: ["type": "duoduo_said", "speech_id": "c-1", "text": "会下雨"])
        guard case .reply(let id1, false, "明天") = a.first, case .reply(let id2, false, "明天会下雨") = b.first else {
            return XCTFail("\(a) \(b)")
        }
        XCTAssertEqual(id1, id2)
        // The final answer replaces the partial text under the same id, then REPLY_DONE.
        let f = t.handle(frame: final("明天会下雨，带伞。", speech: "c-1"))
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
        XCTAssertEqual(t.handle(frame: final("  ", speech: "c-3")), [])
        XCTAssertEqual(t.handle(frame: ["type": "transcript", "row": [:]]), [])
        XCTAssertEqual(t.rows([ImlogEntry(at: "x", speaker: "多多", kind: "reaction", text: "我看看")]), [])
    }

    /// A batch of rows the phone missed (replay or `GET /api/imlog?since=`): the newest answer
    /// goes to the device, once.
    func testRowsDeliverTheNewestUnseenAnswer() {
        var t = ReplyTracker()
        let rows = [ImlogEntry(at: "1", kind: "human", text: "你好"), answer("旧回答"),
                    ImlogEntry(at: "2", kind: "typed", text: "问题", utt_id: "m1"), answer("新回答", ids: ["m1"])]
        let out = t.rows(rows)
        guard case .reply(let id, true, "新回答") = out.first else { return XCTFail("\(out)") }
        XCTAssertEqual(out.last, .replyDone(replyID: id))
    }

    func testRowsSkipAFilesRowWithoutText() {
        var t = ReplyTracker()
        let files = ImlogEntry(at: "2", speaker: "多多", kind: "answer", text: "",
                               attachments: [ChannelAttachment(name: "a.png", mime: "image/png")])
        guard case .reply(_, true, "发了") = t.rows([answer("发了"), files]).first else { return XCTFail() }
    }

    /// The row of an answer sent live closes it: nothing is sent again, and it is forgotten.
    func testAnswerSeenLiveIsNotResentFromItsRow() {
        var t = ReplyTracker()
        XCTAssertEqual(t.handle(frame: final("好的", ids: ["m1"])).count, 2)
        XCTAssertEqual(t.memory.delivered.count, 1)
        XCTAssertEqual(t.rows([answer("好的\n", ids: ["m1"])]), [])
        XCTAssertTrue(t.memory.delivered.isEmpty)
    }

    /// A truncated row matches the live answer by its whole text.
    func testTruncatedRowMatchesByFullText() {
        var t = ReplyTracker()
        _ = t.handle(frame: final("明天上午有两个会", ids: ["m1"]))
        var row = answer("明天上午", ids: ["m1"])
        row.truncated = true
        row.full_text = "明天上午有两个会"
        XCTAssertEqual(t.rows([row]), [])
    }

    /// Two answers with the same text are two answers: the second live one is sent too.
    func testRepeatedTextLiveIsSentAgain() {
        var t = ReplyTracker()
        XCTAssertEqual(t.handle(frame: final("好的")).count, 2)
        XCTAssertEqual(t.handle(frame: final("好的")).count, 2)
    }

    /// A reinstall empties the memory; the time floor keeps the new ids above the old ones.
    func testReplyIDsStayUniqueAcrossAReinstall() {
        var t = ReplyTracker()
        t.clock = { 1_800_000_000 }
        var old: [UInt32] = []
        for text in ["一", "二", "三"] {
            guard case .reply(let id, true, _) = t.handle(frame: final(text)).first else { return XCTFail() }
            old.append(id)
        }
        XCTAssertEqual(old, [1_800_000_000, 1_800_000_001, 1_800_000_002])
        var fresh = ReplyTracker()
        fresh.clock = { 1_800_000_060 }
        guard case .reply(let id, true, _) = fresh.handle(frame: final("四")).first else { return XCTFail() }
        XCTAssertGreaterThan(id, old.max()!)
    }

    func testDeliveredSurvivesRelaunch() {
        var t = ReplyTracker()
        t.clock = { 0 }
        _ = t.handle(frame: final("好的", ids: ["m1"], speech: "c-7"))
        var u = ReplyTracker()
        u.clock = { 0 }
        u.memory = t.memory
        XCTAssertEqual(u.rows([answer("好的", ids: ["m1"])]), [])
        // Ids keep growing after a relaunch.
        guard case .reply(let id, true, _) = u.handle(frame: final("新的")).first else { return XCTFail() }
        XCTAssertEqual(id, t.memory.lastReplyID + 1)
    }

    func testReplyIDsGrowByOneAndPartialsShareTheFinalsID() {
        var t = ReplyTracker()
        t.clock = { 0 }
        var ids: [UInt32] = []
        for (i, text) in ["一", "二", "三"].enumerated() {
            guard case .reply(let id, true, text) = t.handle(frame: final(text, speech: "c-\(i)")).first else { return XCTFail() }
            ids.append(id)
        }
        XCTAssertEqual(ids, [1, 2, 3])
        guard case .reply(let p, false, _) = t.handle(frame: ["type": "duoduo_said", "speech_id": "c-9", "text": "四"]).first,
              case .reply(let f, true, _) = t.handle(frame: final("四。", speech: "c-9")).first
        else { return XCTFail() }
        XCTAssertEqual(p, 4)
        XCTAssertEqual(f, 4)
        // Wraps past 0, never sending it.
        var w = ReplyTracker()
        w.clock = { 0 }
        w.memory.lastReplyID = .max
        guard case .reply(let z, true, _) = w.handle(frame: final("x")).first else { return XCTFail() }
        XCTAssertEqual(z, 1)
    }

    // MARK: correlation by message_ids

    func testTheAnswerNamingTheMessageIsTheReply() {
        var t = ReplyTracker()
        t.expect(messageID: "m2")
        XCTAssertTrue(t.awaiting)
        // Partials are not forwarded while a message waits: they name no message.
        XCTAssertEqual(t.handle(frame: ["type": "duoduo_said", "speech_id": "c-1", "text": "别的"]), [])
        let out = t.handle(frame: final("合并的回答", ids: ["m1", "m2"], speech: "c-1"))
        guard case .reply(let id, true, "合并的回答") = out.first else { return XCTFail("\(out)") }
        XCTAssertEqual(out.last, .replyDone(replyID: id))
        XCTAssertFalse(t.awaiting)
    }

    /// An answer to other inputs is forwarded like any answer, and the wait goes on.
    func testAnAnswerToOtherInputsDoesNotEndTheWait() {
        var t = ReplyTracker()
        t.expect(messageID: "m2")
        XCTAssertEqual(t.handle(frame: final("房间里的回答", ids: [])).count, 2)
        XCTAssertEqual(t.handle(frame: final("别的消息的回答", ids: ["m1"])).count, 2)
        XCTAssertTrue(t.awaiting)
        XCTAssertEqual(t.handle(frame: ["type": "turn", "phase": "idle", "message_ids": ["m1"]]), [])
        XCTAssertTrue(t.awaiting)
    }

    func testWithoutAMessageIDTheNextAnswerIsTheReply() {
        var t = ReplyTracker()
        t.expect(messageID: nil)
        XCTAssertEqual(t.handle(frame: final("下一条", ids: ["zz"])).count, 2)
        XCTAssertFalse(t.awaiting)
    }

    /// The answer came while the socket was down: its row (replayed or fetched) names the
    /// message and is the reply, even with a newer answer in the batch.
    // ble-protocol §7 item 10: with the app in front a forwarded answer is quiet; the answer to a
    // Passport press never is.
    func testQuietFollowsTheDisplayExceptForThePressAnswer() {
        var t = ReplyTracker()
        guard case .reply(let proactive, false, _) = t.handle(frame: ["type": "duoduo_said", "speech_id": "c-1", "text": "早"]).first
        else { return XCTFail() }
        XCTAssertTrue(t.isQuiet(replyID: proactive, display: .phone))
        XCTAssertTrue(t.isQuiet(replyID: proactive, display: .phoneAwake))
        XCTAssertFalse(t.isQuiet(replyID: proactive, display: .passport))
        XCTAssertFalse(t.isQuiet(replyID: proactive, display: .later))

        t.expect(messageID: "m1")
        // Another answer during the wait is forwarded as usual: quiet in front.
        guard case .reply(let other, true, _) = t.handle(frame: final("别的", ids: ["m0"])).first else { return XCTFail() }
        XCTAssertTrue(t.isQuiet(replyID: other, display: .phone))
        // The press's answer alerts as before, whatever the display.
        guard case .reply(let reply, true, _) = t.handle(frame: final("回答", ids: ["m1"])).first else { return XCTFail() }
        XCTAssertFalse(t.awaiting)
        XCTAssertFalse(t.isQuiet(replyID: reply, display: .phone))
        XCTAssertFalse(t.isQuiet(replyID: reply, display: .phoneAwake))
        // The next answer, with no press pending, is quiet again in front.
        guard case .reply(let next, true, _) = t.handle(frame: final("之后")).first else { return XCTFail() }
        XCTAssertTrue(t.isQuiet(replyID: next, display: .phone))
    }

    func testPartialsOfAnAdoptedWaitAnswerThePress() {
        // A wait adopted from KEEPALIVE has no message id: the next answer, partials included, is
        // the press's answer and is never quiet.
        var t = ReplyTracker()
        t.expect(messageID: nil)
        guard case .reply(let p, false, _) = t.handle(frame: ["type": "duoduo_said", "speech_id": "c-2", "text": "好"]).first
        else { return XCTFail() }
        XCTAssertFalse(t.isQuiet(replyID: p, display: .phone))
        guard case .reply(let f, true, _) = t.handle(frame: final("好的", speech: "c-2")).first else { return XCTFail() }
        XCTAssertEqual(f, p)
        XCTAssertFalse(t.isQuiet(replyID: f, display: .phone))
    }

    func testRowsDeliverTheAnswerNamingTheWaitedMessage() {
        var t = ReplyTracker()
        t.expect(messageID: "m9")
        let rows = [answer("对的回答", ids: ["m9"]), answer("更晚的别的回答", ids: ["m8"])]
        let out = t.rows(rows)
        guard case .reply(let id, true, "对的回答") = out.first else { return XCTFail("\(out)") }
        XCTAssertEqual(out.last, .replyDone(replyID: id))
        XCTAssertFalse(t.awaiting)
    }

    func testRowsWithoutTheWaitedMessageForwardTheNewestAndKeepWaiting() {
        var t = ReplyTracker()
        t.expect(messageID: "m10")
        guard case .reply(_, true, "更晚的") = t.rows([answer("早的", ids: ["m8"]), answer("更晚的", ids: ["m9"])]).first
        else { return XCTFail() }
        XCTAssertTrue(t.awaiting)
    }

    // MARK: work status (docs/ble-protocol.md §9)

    func testWorkReceivedFollowsTheMessagesDelivery() {
        var t = ReplyTracker()
        t.expect(messageID: "m1")
        // Work of a turn that is not the message's comes before its delivery: nothing.
        XCTAssertEqual(t.handle(frame: ["type": "turn", "phase": "thinking", "message_ids": []]), [])
        XCTAssertEqual(t.handle(frame: ["type": "turn", "phase": "received", "message_ids": []]), [])
        XCTAssertEqual(t.handle(frame: ["type": "turn", "phase": "received", "message_ids": ["m1"]]),
                       [.work(phase: .received, label: "")])
        XCTAssertEqual(t.handle(frame: ["type": "turn", "phase": "thinking", "message_ids": []]),
                       [.work(phase: .thinking, label: "")])
        // The tool label is not forwarded in v1.
        XCTAssertEqual(t.handle(frame: ["type": "turn", "phase": "tool", "label": "web_search", "message_ids": ["m1"]]),
                       [.work(phase: .tool, label: "")])
        for phase in ["speaking", "done", "later"] {
            XCTAssertEqual(t.handle(frame: ["type": "turn", "phase": phase, "message_ids": ["m1"]]), [], phase)
        }
        XCTAssertTrue(t.awaiting)
    }

    func testTurnFramesBecomeWorkOnlyWhileWaiting() {
        var t = ReplyTracker()
        XCTAssertEqual(t.handle(frame: ["type": "turn", "phase": "received", "message_ids": ["m1"]]), [])
        XCTAssertEqual(t.handle(frame: ["type": "turn", "phase": "thinking", "message_ids": ["m1"]]), [])
    }

    func testAnswerEndsTheWaitAndALaterIdleIsIgnored() {
        var t = ReplyTracker()
        t.expect(messageID: "m1")
        _ = t.handle(frame: ["type": "turn", "phase": "received", "message_ids": ["m1"]])
        let out = t.handle(frame: final("好的", ids: ["m1"], speech: "c-1"))
        XCTAssertEqual(out.count, 2)
        guard case .replyDone(let id) = out.last else { return XCTFail("\(out)") }
        XCTAssertNotEqual(id, PocketConstants.noReplyID)
        XCTAssertFalse(t.awaiting)
        XCTAssertEqual(t.handle(frame: ["type": "turn", "phase": "idle", "message_ids": ["m1"]]), [])
        XCTAssertEqual(t.handle(frame: ["type": "turn", "phase": "thinking", "message_ids": []]), [])
    }

    func testIdleOfTheMessagesTurnEndsTheWaitWithReplyDoneZero() {
        var t = ReplyTracker()
        t.expect(messageID: "m1")
        XCTAssertEqual(t.handle(frame: ["type": "turn", "phase": "idle", "message_ids": ["m1"]]),
                       [.work(phase: .idle, label: ""), .replyDone(replyID: PocketConstants.noReplyID)])
        XCTAssertFalse(t.awaiting)
        // A late answer still goes out as a reply.
        let late = t.handle(frame: final("晚到的回答", ids: ["m1"], speech: "c-9"))
        guard case .reply(_, true, "晚到的回答") = late.first else { return XCTFail("\(late)") }
    }

    /// `brain_unreachable` for the waited message: no answer will come.
    func testBrainUnreachableEndsTheWait() {
        var t = ReplyTracker()
        t.expect(messageID: "m1")
        XCTAssertEqual(t.messageFailed("m2"), [])
        XCTAssertEqual(t.messageFailed("m1"), [.replyDone(replyID: PocketConstants.noReplyID)])
        XCTAssertFalse(t.awaiting)
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
        guard case .reply(let a, true, "早上好") = t.handle(frame: final("早上好")).first else { return XCTFail() }
        // Link down when it arrived: the link-up replay has it.
        XCTAssertEqual(t.answerForNewLink?.replyID, a)
        t.handedToLink(replyID: a)
        XCTAssertNil(t.answerForNewLink)
        // Its row is not sent again; a newer answer from background refresh is.
        guard case .reply(let b, true, "提醒你开会") = t.rows([answer("早上好"), answer("提醒你开会")]).first
        else { return XCTFail() }
        XCTAssertGreaterThan(b, a)
        XCTAssertEqual(t.answerForNewLink?.text, "提醒你开会")
    }

    func testForgetDeliveredDropsLiveAnswersWithoutRows() {
        var t = ReplyTracker()
        _ = t.handle(frame: final("一"))
        t.forgetDelivered()
        XCTAssertTrue(t.memory.delivered.isEmpty)
    }

    /// The newest answer and the device's last id survive a relaunch.
    func testMemoryRoundTrip() throws {
        var t = ReplyTracker()
        _ = t.handle(frame: final("一", ids: ["m1"]))
        let data = try JSONEncoder().encode(t.memory)
        var u = ReplyTracker()
        u.memory = try JSONDecoder().decode(ReplyTracker.Memory.self, from: data)
        XCTAssertEqual(u.answerForNewLink?.text, "一")
        XCTAssertEqual(u.memory.delivered.first?.messages, ["m1"])
    }

    /// A reconnect spanned the message's `turn received`: `ready.turn` brings WORK back.
    func testReadyTurnRestoresWork() {
        var t = ReplyTracker()
        t.expect(messageID: "m1")
        XCTAssertEqual(t.restore(turn: .init(messageIDs: ["m0"], phase: "thinking")), [])
        XCTAssertEqual(t.restore(turn: .init(messageIDs: ["m0", "m1"], phase: "tool")),
                       [.work(phase: .received, label: ""), .work(phase: .tool, label: "")])
        XCTAssertEqual(t.restore(turn: .init(messageIDs: ["m1"], phase: "tool")), [])
        XCTAssertEqual(t.handle(frame: ["type": "turn", "phase": "thinking", "message_ids": []]),
                       [.work(phase: .thinking, label: "")])
    }
}
