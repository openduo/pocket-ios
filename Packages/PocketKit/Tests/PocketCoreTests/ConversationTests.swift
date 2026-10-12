// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import XCTest
@testable import PocketCore

final class HistoryCacheTests: XCTestCase {
    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    func testReplaceIsAuthoritativeAndAppendDeduplicates() {
        let dir = tempDir()
        let c = HistoryCache(directory: dir)
        let a = ImlogEntry(at: "2026-10-07T01:00:00.000Z", kind: "typed", text: "hi", utt_id: "u1")
        let b = ImlogEntry(at: "2026-10-07T01:00:01.000Z", speaker: "多多", kind: "answer", text: "hello")
        c.replace(day: "2026-10-07", entries: [a])
        // The live append repeats a and adds b.
        XCTAssertEqual(c.append(day: "2026-10-07", entries: [a, b]), [b])
        XCTAssertEqual(c.entries("2026-10-07"), [a, b])
        // A later fetch replaces the day whole, even if it drops a row.
        c.replace(day: "2026-10-07", entries: [b])
        XCTAssertEqual(c.entries("2026-10-07"), [b])
        // Survives a reload from disk, days in order.
        c.replace(day: "2026-10-05", entries: [a])
        let again = HistoryCache(directory: dir)
        XCTAssertEqual(again.cachedDays, ["2026-10-05", "2026-10-07"])
        XCTAssertEqual(again.all(), [a, b])
        XCTAssertNotNil(again.lastFetch)
    }

    func testTypedKeyUsesUttID() {
        let a = ImlogEntry(at: "x", kind: "typed", text: "same", utt_id: "u1")
        var b = a
        b.at = "y"
        XCTAssertEqual(a.key, b.key)
        XCTAssertNotEqual(ImlogEntry(at: "x", kind: "human", text: "t").key, ImlogEntry(at: "y", kind: "human", text: "t").key)
    }

    /// Rows with a cursor are keyed by it: two rows with the same text are two rows.
    func testRowsWithSeqAreKeyedBySeq() {
        let a = ImlogEntry(seq: 1_900_000_000_000, at: "x", kind: "human", text: "t")
        var b = a
        b.seq = 1_900_000_000_001
        XCTAssertEqual(a.key, "seq:1900000000000")
        XCTAssertNotEqual(a.key, b.key)
    }

    func testInvalidDayIsIgnored() {
        let c = HistoryCache(directory: tempDir())
        c.replace(day: "../evil", entries: [])
        XCTAssertTrue(c.cachedDays.isEmpty)
    }
}

final class DayStringTests: XCTestCase {
    func testArithmetic() {
        XCTAssertEqual(DayString.adding(-1, to: "2026-03-01"), "2026-02-28")
        XCTAssertEqual(DayString.range(after: "2026-10-05", through: "2026-10-07"), ["2026-10-06", "2026-10-07"])
        XCTAssertEqual(DayString.range(after: "2026-10-07", through: "2026-10-07"), [])
        XCTAssertFalse(DayString.isValid("2026-02-30"))
    }
}

final class OutboxTests: XCTestCase {
    func testQueueSendDeliverReconcile() {
        var o = Outbox()
        let t = OutboxItem(body: .text("晚上的会改到八点了", attachments: []))
        let v = OutboxItem(body: .voice(voiceID: UUID(), durationMs: 3000))
        o.add(t)
        o.add(v)
        XCTAssertEqual(o.sendable().map(\.id), [t.id, v.id])
        o.set(t.id, .sending)
        XCTAssertEqual(o.sendable().map(\.id), [v.id])
        o.set(t.id, .accepted(at: nil, cleaned: nil))
        o.set(v.id, .failed(reason: "识别出错 · 轻点重试"))
        XCTAssertTrue(o.sendable().isEmpty)
        // The row whose utt_id is the message id arrives: the item leaves, the failed one stays.
        let removed = o.reconcile(with: [ImlogEntry(at: "a", kind: "typed", text: "x", utt_id: t.messageID)])
        XCTAssertEqual(removed, [t.id])
        XCTAssertEqual(o.items.map(\.id), [v.id])
    }

    /// The message id is fixed at creation: the voice note's id or the item's, lowercased.
    func testMessageIDIsTheIdempotencyKey() {
        let vid = UUID()
        XCTAssertEqual(OutboxItem(body: .voice(voiceID: vid, durationMs: 1)).messageID, vid.uuidString.lowercased())
        let t = OutboxItem(body: .text("a", attachments: []))
        XCTAssertEqual(t.messageID, t.id.uuidString.lowercased())
        var o = Outbox()
        o.add(t)
        XCTAssertEqual(o.item(messageID: t.messageID)?.id, t.id)
    }

    /// An outbox this build cannot read is dropped with its voice packets.
    func testUnreadableOutboxIsDroppedWithItsPackets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"items":[{"state":{"delivered":{}}}]}"#.utf8).write(to: dir.appendingPathComponent("outbox.json"))
        try Data([1]).write(to: dir.appendingPathComponent("voice-x.bin"))
        let s = OutboxStore(directory: dir)
        XCTAssertTrue(s.outbox.items.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testSendingItemIsRequeuedAfterRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = OutboxStore(directory: dir)
        let note = VoiceNote(source: .phone, packets: [Data([1, 2, 3]), Data([4])])
        try s.saveVoice(note)
        let item = OutboxItem(body: .voice(voiceID: note.id, durationMs: 40), state: .sending)
        s.mutate { $0.add(item) }
        let again = OutboxStore(directory: dir)
        XCTAssertEqual(again.outbox.items.first?.state, .queued)
        // Requeued with the same key.
        XCTAssertEqual(again.outbox.items.first?.messageID, note.id.uuidString.lowercased())
        XCTAssertEqual(again.loadVoice(note.id)?.packets, note.packets)
        // Removing the item removes its packets.
        again.mutate { $0.remove(item.id) }
        XCTAssertNil(again.loadVoice(note.id))
    }
}

final class TurnStateTests: XCTestCase {
    func testWorkingBubbleLifecycle() {
        var t = TurnState()
        t.handle(frame: ["type": "turn", "phase": "received", "message_ids": ["m1"]])
        XCTAssertEqual(t.working?.phase, .received)
        XCTAssertEqual(t.working?.messages, ["m1"])
        t.handle(frame: ["type": "turn", "phase": "thinking", "message_ids": ["m1"]])
        XCTAssertEqual(t.working?.phase, .thinking)
        // Per call: early frame without input, the full call, the result.
        t.handle(frame: ["type": "turn", "phase": "tool", "label": "calendar"])
        t.handle(frame: ["type": "turn", "phase": "tool", "label": "calendar", "input_summary": #"{"query":"明天"}"#])
        t.handle(frame: ["type": "turn", "phase": "tool", "label": "calendar ✓"])
        t.handle(frame: ["type": "turn", "phase": "tool", "label": "reminder", "input_summary": #"{"text":"提醒"}"#])
        XCTAssertEqual(t.working?.steps, [.init(name: "calendar", summary: "明天", done: true, hasInput: true),
                                          .init(name: "reminder", summary: "提醒", done: false, hasInput: true)])
        XCTAssertEqual(t.working?.toolLabel, "reminder 提醒")
        XCTAssertEqual(t.working?.foldedSteps, 1)
        t.handle(frame: ["type": "duoduo_said", "speech_id": "c-m1", "text": "好，"])
        t.handle(frame: ["type": "duoduo_said", "speech_id": "c-m1", "text": "明天"])
        t.handle(frame: ["type": "duoduo_said", "speech_id": "s1", "kind": "reaction", "text": "我看看"])
        XCTAssertEqual(t.working?.text, "好，明天")
        XCTAssertEqual(t.working?.phase, .streaming)
        t.handle(frame: ["type": "answer_final", "message_ids": ["m1"], "speech_id": "c-m1", "text": "好，明天三点。"])
        XCTAssertNil(t.working)
        XCTAssertEqual(t.provisional.map(\.text), ["好，明天三点。"])
        // The log row settles the provisional answer and keeps its steps.
        XCTAssertTrue(t.settle(with: [ImlogEntry(at: "a", speaker: "多多", kind: "answer", text: "好，明天三点。")]))
        XCTAssertTrue(t.provisional.isEmpty)
        XCTAssertEqual(t.trace(forAnswer: "好，明天三点。").steps.count, 2)
        XCTAssertTrue(t.trace(forAnswer: "好，明天三点。").steps.allSatisfy(\.done))
    }

    func testIdleEndsATurnWithoutAnswer() {
        var t = TurnState()
        t.expect(messageID: "m1")
        // Idle of another message's turn does not end ours.
        XCTAssertFalse(t.handle(frame: ["type": "turn", "message_ids": ["m9"], "phase": "idle"]))
        XCTAssertFalse(t.handle(frame: ["type": "turn", "message_ids": [], "phase": "idle"]))
        XCTAssertNotNil(t.working)
        XCTAssertTrue(t.handle(frame: ["type": "turn", "message_ids": ["m1"], "phase": "idle"]))
        XCTAssertNil(t.working)
        XCTAssertTrue(t.provisional.isEmpty)
        // A room-speech turn (no messages) ends on any idle.
        t.handle(frame: ["type": "turn", "phase": "received", "message_ids": []])
        XCTAssertTrue(t.handle(frame: ["type": "turn", "message_ids": [], "phase": "idle"]))
    }

    /// An answer to other inputs does not end the bubble; it stays a provisional answer.
    func testAnswerToOtherInputsKeepsTheBubble() {
        var t = TurnState()
        t.expect(messageID: "m2")
        t.handle(frame: ["type": "duoduo_said", "speech_id": "c-x", "text": "房间"])
        t.handle(frame: ["type": "answer_final", "message_ids": [], "speech_id": "c-x", "text": "房间里的回答"])
        XCTAssertEqual(t.working?.messages, ["m2"])
        XCTAssertEqual(t.working?.text, "")
        XCTAssertEqual(t.provisional.map(\.text), ["房间里的回答"])
    }

    /// The answer reached the log while the socket was down, so no `answer_final` frame came;
    /// the 「收到了」 bubble must not stay under the answer.
    func testWorkingEndsWhenItsAnswerIsInTheLog() {
        let log = [
            ImlogEntry(at: "2030-01-01T09:00:00.000Z", kind: "typed", text: "明天有什么安排", utt_id: "m8",
                       voice_source: "passport"),
            ImlogEntry(at: "2030-01-01T09:00:20.000Z", speaker: "多多", kind: "answer", text: "明天上午有两个会",
                       message_ids: ["m8"]),
            ImlogEntry(at: "2030-01-01T09:02:30.000Z", kind: "typed", text: "出门要带什么？", utt_id: "m9",
                       voice_source: "passport"),
        ]
        var t = TurnState()
        t.expect(messageID: "m9")
        // The earlier answer is not this turn's.
        XCTAssertFalse(t.endIfAnswered(in: log))
        XCTAssertEqual(t.working?.phase, .received)
        let answered = log + [ImlogEntry(at: "2030-01-01T09:02:33.000Z", speaker: "多多", kind: "answer",
                                         text: "记得带伞和充电器", message_ids: ["m9"])]
        XCTAssertTrue(t.endIfAnswered(in: answered))
        XCTAssertNil(t.working)
    }

    func testReceivedFromAnotherSourceStartsWorking() {
        var t = TurnState()
        t.handle(frame: ["type": "turn", "message_ids": ["m1"], "phase": "received", "text": "x"])
        XCTAssertEqual(t.working?.messages, ["m1"])
        // A message folded into the running turn joins it.
        t.handle(frame: ["type": "turn", "message_ids": ["m2"], "phase": "received"])
        XCTAssertEqual(t.working?.messages, ["m1", "m2"])
    }

    /// `ready.turn`: none ends a bubble whose turn closed while the socket was down; an open one
    /// restores it.
    func testRestoreFromReady() {
        var t = TurnState()
        t.expect(messageID: "m1")
        XCTAssertTrue(t.restore(nil))
        XCTAssertNil(t.working)
        XCTAssertTrue(t.restore(.init(messageIDs: ["m2"], phase: "tool")))
        XCTAssertEqual(t.working?.messages, ["m2"])
        XCTAssertEqual(t.working?.phase, .tool)
    }

    func testBrainUnreachableDropsTheMessage() {
        var t = TurnState()
        t.handle(frame: ["type": "turn", "message_ids": ["m1", "m2"], "phase": "received"])
        XCTAssertTrue(t.messageFailed("m1"))
        XCTAssertEqual(t.working?.messages, ["m2"])
        XCTAssertTrue(t.messageFailed("m2"))
        XCTAssertNil(t.working)
    }
}

final class ThreadBuilderTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Shanghai")!
    private var now: Date { ThreadBuilder.parse("2026-10-07T04:00:00.000Z")! } // 12:00 local

    func testRowsSeparatorsAndDelivery() {
        let entries = [
            ImlogEntry(at: "2026-10-06T14:40:00.000Z", kind: "typed", text: "明早八点叫我", utt_id: "u0"),
            ImlogEntry(at: "2026-10-06T14:40:05.000Z", speaker: "多多", kind: "answer", text: "好", unspoken: true),
            ImlogEntry(at: "2026-10-07T00:12:00.000Z", kind: "typed", text: "带伞吗", utt_id: "u1", voice_source: "passport"),
            ImlogEntry(at: "2026-10-07T00:12:03.000Z", speaker: "多多", kind: "reaction", text: "我看看"),
            ImlogEntry(at: "2026-10-07T00:12:09.000Z", speaker: "多多", kind: "answer", text: "要带", truncated: true,
                       full_text: "要带，下午有雨"),
        ]
        let rows = ThreadBuilder(now: now, timeZone: tz).build(.init(entries: entries, durations: ["u1": 6000]))
        let labels = rows.compactMap { if case .separator(_, let l) = $0 { l } else { nil } }
        XCTAssertEqual(labels, ["昨天 22:40", "今天 08:12"])
        // Reactions are not rows.
        XCTAssertFalse(rows.contains { if case .duoduo(let d) = $0 { d.text == "我看看" } else { false } })
        guard case .mine(let voice) = rows[4] else { return XCTFail("\(rows)") }
        XCTAssertEqual(voice.voiceSource, "passport")
        XCTAssertEqual(voice.durationMs, 6000)
        XCTAssertEqual(voice.delivery, "已送达")
        guard case .mine(let first) = rows[1] else { return XCTFail() }
        XCTAssertNil(first.delivery)
        guard case .duoduo(let unspoken) = rows[2], case .duoduo(let cut) = rows[5] else { return XCTFail() }
        XCTAssertNil(unspoken.spoken)
        XCTAssertEqual(cut.spoken, "只播了一部分")
        // A truncated answer shows the whole text.
        XCTAssertEqual(cut.text, "要带，下午有雨")
    }

    func testHeardRunsFold() {
        var entries: [ImlogEntry] = []
        for i in 0..<5 {
            entries.append(ImlogEntry(at: "2026-10-07T03:00:0\(i).000Z", speaker: "V\(i % 2 + 1)", kind: "human", text: "line \(i)"))
        }
        let rows = ThreadBuilder(now: now, timeZone: tz).build(.init(entries: entries))
        guard case .heard(let h) = rows.last else { return XCTFail("\(rows)") }
        XCTAssertEqual(h.lines.map(\.text), ["line 2", "line 3", "line 4"])
        XCTAssertEqual(h.folded.count, 2)
    }

    func testPendingRowsHideOnceLoggedAndWorkingComesLast() {
        let logged = OutboxItem(body: .text("a", attachments: []), state: .accepted(at: nil, cleaned: nil))
        let queued = OutboxItem(body: .text("b", attachments: []))
        var turn = TurnState()
        turn.expect(messageID: "u2")
        let rows = ThreadBuilder(now: now, timeZone: tz).build(.init(
            entries: [ImlogEntry(at: "2026-10-07T03:00:00.000Z", kind: "typed", text: "a", utt_id: logged.messageID)],
            outbox: [logged, queued], turn: turn, undelivered: [logged.messageID]))
        let pendingIDs = rows.compactMap { if case .pending(let p) = $0 { p.id } else { nil } }
        XCTAssertEqual(pendingIDs, [queued.id])
        guard case .working = rows.last else { return XCTFail() }
        guard case .mine(let m) = rows[1] else { return XCTFail() }
        XCTAssertEqual(m.delivery, "没送到多多")
    }
}

final class DuoduoAttachmentTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Shanghai")!

    /// The row the channel writes for files 多多 sent (`showBrainAttachments`), as `/live` and
    /// `/api/imlog` carry it.
    private let fileRowJSON = #"""
    {"type":"row","seq":1791000001000,"row":{"seq":1791000001000,"at":"2026-10-07T12:00:01.000Z","speaker":"多多","kind":"answer","text":"","attachments":[{"name":"示例图.png","mime":"image/png","sha256":"0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"},{"name":"report.pdf","mime":"application/pdf"}]}}
    """#

    private func entries() throws -> [ImlogEntry] {
        let frame = try JSONSerialization.jsonObject(with: Data(fileRowJSON.utf8)) as! [String: Any]
        guard case .row(let seq, let e) = LiveEvent.decode(frame) else { return [] }
        XCTAssertEqual(seq, 1_791_000_001_000)
        return [e]
    }

    func testFileRowDecodesWithAttachments() throws {
        let e = try entries()
        XCTAssertEqual(e.count, 1)
        XCTAssertTrue(e[0].isAnswer)
        XCTAssertEqual(e[0].attachments?.map(\.name), ["示例图.png", "report.pdf"])
        XCTAssertEqual(e[0].attachments?.first?.isInlineImage, true)
        XCTAssertNil(e[0].attachments?.last?.sha256)
        XCTAssertEqual(ChannelPaths.attachment(room: "study", e[0].attachments![0]),
                       "/api/attachment?room=study&sha256=0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0&mime=image/png&name=%E7%A4%BA%E4%BE%8B%E5%9B%BE.png")
        // A path-less name has no URL.
        XCTAssertNil(ChannelPaths.attachment(room: "study", e[0].attachments![1]))
    }

    func testFileRowBecomesADuoduoRowWithoutSpokenMeta() throws {
        let answer = ImlogEntry(at: "2026-10-07T12:00:00.000Z", speaker: "多多", kind: "answer", text: "发了")
        let rows = ThreadBuilder(now: ThreadBuilder.parse("2026-10-07T13:00:00.000Z")!, timeZone: tz)
            .build(.init(entries: [answer] + (try entries())))
        let duo = rows.compactMap { if case .duoduo(let d) = $0 { d } else { nil } }
        XCTAssertEqual(duo.count, 2)
        XCTAssertEqual(duo[0].text, "发了")
        XCTAssertTrue(duo[0].attachments.isEmpty)
        XCTAssertEqual(duo[1].attachments.count, 2)
        XCTAssertNil(duo[1].spoken)
        XCTAssertTrue(duo[1].trace.steps.isEmpty)
    }

    func testHistoryCacheKeepsAttachments() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = try entries()
        HistoryCache(directory: dir).replace(day: "2026-10-07", entries: e)
        XCTAssertEqual(HistoryCache(directory: dir).entries("2026-10-07").first?.attachments, e[0].attachments)
    }
}

final class ChannelAPITests: XCTestCase {
    func testStateDecodesLimitsAndFallsBack() {
        let withLimit = Data(#"{"room":"study","room_name":"书房","date":"2026-10-07","daemon_ok":true,"cerebellum_ok":false,"capture":{"owner":null},"controls":{"mute":{"active":true}},"limits":{"upload_max_bytes":10485760}}"#.utf8)
        let s = RoomState.decode(withLimit)!
        XCTAssertEqual(s.uploadMaxBytes, 10_485_760)
        XCTAssertEqual(s.roomName, "书房")
        XCTAssertEqual(s.cerebellumOK, false)
        XCTAssertTrue(s.muted)
        XCTAssertEqual(UploadPolicy.check(size: 11_000_000, state: s), .tooLarge(limit: 10_485_760))
        XCTAssertEqual(UploadPolicy.check(size: 100, state: s), .ok)

        // An older channel: no limits field; the app sends and learns from 413.
        let old = RoomState.decode(Data(#"{"room":"study","date":"2026-10-07"}"#.utf8))!
        XCTAssertNil(old.uploadMaxBytes)
        XCTAssertEqual(UploadPolicy.check(size: 1 << 30, state: old), .ok)
        XCTAssertEqual(UploadPolicy.outcome(status: 413, body: Data(#"{"error":"body too large"}"#.utf8), name: "a", mime: "b", state: old),
                       .tooLarge(limit: nil))

        // A null bound: uploads are off.
        let off = RoomState.decode(Data(#"{"room":"p","limits":{"upload_max_bytes":null}}"#.utf8))!
        XCTAssertEqual(UploadPolicy.check(size: 1, state: off), .disabled)
    }

    func testUploadOutcomeAndTypedMessageBody() throws {
        let ok = UploadPolicy.outcome(status: 200, body: Data(#"{"name":"a.jpg","mime":"image/jpeg","path":"/inbox/a.jpg","sha256":"ab"}"#.utf8),
                                      name: "a.jpg", mime: "image/jpeg", state: nil)
        guard case .uploaded(let a) = ok else { return XCTFail("\(ok)") }
        XCTAssertEqual(a.path, "/inbox/a.jpg")
        let body = ChannelPaths.typedMessageBody(text: "看看", attachments: [a])
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual((obj["attachments"] as! [[String: Any]]).first?["path"] as? String, "/inbox/a.jpg")
        XCTAssertEqual(UploadPolicy.outcome(status: 503, body: Data(#"{"error":"bridge.upload_max_bytes must be a positive integer"}"#.utf8),
                                            name: "a", mime: "b", state: nil), .disabled)
        XCTAssertEqual(UploadPolicy.limitText(10_485_760), "文件太大（上限 10 MB）")
        XCTAssertEqual(UploadPolicy.limitText(1_572_864), "文件太大（上限 1.5 MB）")
    }

    func testPathsEscapeRoom() {
        XCTAssertEqual(ChannelPaths.state(room: "a&b"), "/api/state?room=a%26b")
        XCTAssertEqual(ChannelPaths.messages(room: "a&b"), "/api/messages?room=a%26b")
        XCTAssertEqual(ChannelPaths.live(room: "a&b", audio: false), "/live?room=a%26b&audio=0")
        XCTAssertEqual(ChannelPaths.live(room: "r", since: 1_791_000_000_000, audio: true),
                       "/live?room=r&since=1791000000000&audio=1")
        XCTAssertEqual(ChannelPaths.speech(room: "a&b"), "/api/speech?room=a%26b")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: ChannelPaths.speechBody(text: "你好")) as? [String: String],
                       ["text": "你好"])
        XCTAssertEqual(ChannelPaths.imlog(room: "r", since: 5), "/api/imlog?room=r&since=5")
        XCTAssertEqual(ChannelPaths.typedMessageHeaders(key: "k"), ["Content-Type": "application/json", "Idempotency-Key": "k"])
        XCTAssertEqual(ChannelPaths.attachment(room: "r", ChannelAttachment(name: "报价 v2.pdf", mime: "application/pdf", sha256: "ff")),
                       "/api/attachment?room=r&sha256=ff&mime=application/pdf&name=%E6%8A%A5%E4%BB%B7%20v2.pdf")
    }
}

final class LiveEventTests: XCTestCase {
    private func decode(_ json: String) -> LiveEvent? {
        LiveEvent.decode(try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
    }

    func testReadyRowAndMessageEvents() {
        XCTAssertEqual(decode(#"{"type":"ready","seq":1791000000000,"turn":{"message_ids":["m1"],"phase":"thinking"},"messages":[{"id":"m2","state":"cleaned"},{"id":"m3","state":"accepted"}]}"#),
                       .ready(.init(seq: 1_791_000_000_000, turn: .init(messageIDs: ["m1"], phase: "thinking"),
                                    messages: ["m2": "cleaned", "m3": "accepted"])))
        XCTAssertEqual(decode(#"{"type":"ready","seq":7,"turn":null,"messages":[]}"#), .ready(.init(seq: 7)))
        guard case .row(5, let e) = decode(#"{"type":"row","seq":5,"row":{"seq":5,"at":"a","speaker":"多多","kind":"answer","text":"x","message_ids":["m1"],"truncated":true,"full_text":"xyz"}}"#)
        else { return XCTFail() }
        XCTAssertEqual(e.message_ids, ["m1"])
        XCTAssertEqual(e.shownText, "xyz")
        XCTAssertEqual(decode(#"{"type":"message","id":"m1","state":"cleaned","text":"你好"}"#), .cleaned(id: "m1", text: "你好"))
        XCTAssertEqual(decode(#"{"type":"message","id":"m1","state":"failed","reason":"asr_failed"}"#),
                       .failed(id: "m1", reason: .asrFailed))
        XCTAssertNil(decode(#"{"type":"turn","phase":"idle","message_ids":[]}"#))
    }

    func testCursorAdmitsOnlyNewerRows() {
        var c = RowCursor()
        XCTAssertTrue(c.admit(10))
        XCTAssertFalse(c.admit(10))
        XCTAssertFalse(c.admit(9))
        c.reached(20)
        XCTAssertEqual(c.seq, 20)
        c.reached(15)
        XCTAssertEqual(c.seq, 20)
        XCTAssertTrue(c.admit(21))
    }

    func testSettlementAtReady() {
        let r = LiveEvent.Ready(seq: 1, messages: ["m1": "cleaned"])
        XCTAssertEqual(MessageSettlement.of("m1", ready: r, rowLogged: false), .open(state: "cleaned"))
        XCTAssertEqual(MessageSettlement.of("m2", ready: r, rowLogged: true), .logged)
        XCTAssertEqual(MessageSettlement.of("m3", ready: r, rowLogged: false), .failed)
    }
}

final class VoiceResultWaitTests: XCTestCase {
    func testCleanedIsResultZeroWithTheCleanedText() {
        var w = VoiceResultWait(messageID: "m1")
        XCTAssertNil(w.handle(.cleaned(id: "other", text: "x")))
        XCTAssertNil(w.handle(.row(seq: 1, ImlogEntry(at: "a", kind: "typed", text: "清洗后的", utt_id: "m1"))))
        XCTAssertEqual(w.handle(.cleaned(id: "m1", text: "清洗后的")), .init(code: .transcribed, text: "清洗后的"))
        // Once.
        XCTAssertNil(w.handle(.failed(id: "m1", reason: .brainUnreachable)))
        XCTAssertNil(w.expired(connected: true))
    }

    func testFailuresMapToResultCodes() {
        let cases: [(MessageFailure, ResultCode)] = [(.emptyTranscript, .empty), (.asrFailed, .asrFailed),
                                                     (.perceptionUnavailable, .sendFailed), (.other("x"), .sendFailed)]
        for (reason, code) in cases {
            var w = VoiceResultWait(messageID: "m1")
            XCTAssertEqual(w.handle(.failed(id: "m1", reason: reason))?.code, code, "\(reason)")
        }
    }

    /// Reconnected before RESULT: `ready.messages` and the replayed row decide.
    func testReconnectSettlement() {
        var open = VoiceResultWait(messageID: "m1")
        XCTAssertNil(open.handle(.ready(.init(seq: 1, messages: ["m1": "accepted"]))))
        XCTAssertEqual(open.handle(.cleaned(id: "m1", text: "后来")), .init(code: .transcribed, text: "后来"))

        var logged = VoiceResultWait(messageID: "m1")
        _ = logged.handle(.row(seq: 2, ImlogEntry(at: "a", kind: "typed", text: "行里的", utt_id: "m1")))
        XCTAssertEqual(logged.handle(.ready(.init(seq: 2))), .init(code: .transcribed, text: "行里的"))

        var lost = VoiceResultWait(messageID: "m1")
        XCTAssertEqual(lost.handle(.ready(.init(seq: 2))), .init(code: .sendFailed, text: ""))
    }

    /// The row was replayed before the retry's 202 (the first attempt's receipt was lost): the
    /// 202 settles RESULT 0 with the row's text.
    func testAcceptedAfterTheRowIsResultZero() {
        var w = VoiceResultWait(messageID: "m1")
        XCTAssertNil(w.accepted())
        var r = VoiceResultWait(messageID: "m1")
        _ = r.handle(.row(seq: 2, ImlogEntry(at: "a", kind: "typed", text: "行里的", utt_id: "m1")))
        XCTAssertEqual(r.accepted(), .init(code: .transcribed, text: "行里的"))
        XCTAssertNil(r.accepted())
    }

    func testDeadlineIsSendFailedOrNotConnected() {
        var a = VoiceResultWait(messageID: "m1")
        XCTAssertEqual(a.expired(connected: true)?.code, .sendFailed)
        var b = VoiceResultWait(messageID: "m1")
        XCTAssertEqual(b.expired(connected: false)?.code, .notConnectedToServer)
    }
}
