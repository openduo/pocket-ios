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
        o.set(t.id, .delivered(uttID: "u1", at: nil, transcript: nil, recordAvailable: true))
        o.set(v.id, .failed(reason: "识别出错 · 轻点重试"))
        XCTAssertTrue(o.sendable().isEmpty)
        // The log row with u1 arrives: the delivered item leaves, the failed one stays.
        let removed = o.reconcile(with: [ImlogEntry(at: "a", kind: "typed", text: "x", utt_id: "u1")])
        XCTAssertEqual(removed, [t.id])
        XCTAssertEqual(o.items.map(\.id), [v.id])
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
        XCTAssertEqual(again.loadVoice(note.id)?.packets, note.packets)
        // Removing the item removes its packets.
        again.mutate { $0.remove(item.id) }
        XCTAssertNil(again.loadVoice(note.id))
    }
}

final class TurnStateTests: XCTestCase {
    func testWorkingBubbleLifecycle() {
        var t = TurnState()
        t.expect(uttID: "u1")
        XCTAssertEqual(t.working?.phase, .received)
        t.handle(frame: ["type": "turn", "utt_id": NSNull(), "phase": "thinking"])
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
        t.handle(frame: ["type": "duoduo_said", "speech_id": "c-u1", "text": "好，"])
        t.handle(frame: ["type": "duoduo_said", "speech_id": "c-u1", "text": "明天"])
        t.handle(frame: ["type": "duoduo_said", "speech_id": "s1", "kind": "reaction", "text": "我看看"])
        XCTAssertEqual(t.working?.text, "好，明天")
        XCTAssertEqual(t.working?.phase, .streaming)
        t.handle(frame: ["type": "answer_final", "utt_id": "u1", "speech_id": "c-u1", "text": "好，明天三点。"])
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
        t.expect(uttID: "u1")
        // Idle for another utterance does not end ours.
        XCTAssertFalse(t.handle(frame: ["type": "turn", "utt_id": "u9", "phase": "idle"]))
        XCTAssertNotNil(t.working)
        XCTAssertTrue(t.handle(frame: ["type": "turn", "utt_id": "u1", "phase": "idle"]))
        XCTAssertNil(t.working)
        XCTAssertTrue(t.provisional.isEmpty)
    }

    /// The answer reached the log while the display socket was down, so no `answer_final` frame
    /// came; the 「收到了」 bubble must not stay under the answer.
    func testWorkingEndsWhenItsAnswerIsInTheLog() {
        let log = [
            ImlogEntry(at: "2030-01-01T09:00:00.000Z", kind: "typed", text: "明天有什么安排", utt_id: "inj-8",
                       voice_source: "passport"),
            ImlogEntry(at: "2030-01-01T09:00:20.000Z", speaker: "多多", kind: "answer", text: "明天上午有两个会"),
            ImlogEntry(at: "2030-01-01T09:02:30.000Z", kind: "typed", text: "出门要带什么？", utt_id: "inj-9",
                       voice_source: "passport"),
        ]
        var t = TurnState()
        t.expect(uttID: "inj-9")
        // The earlier answer is not this turn's.
        XCTAssertFalse(t.endIfAnswered(in: log))
        XCTAssertEqual(t.working?.phase, .received)
        let answered = log + [ImlogEntry(at: "2030-01-01T09:02:33.000Z", speaker: "多多", kind: "answer",
                                         text: "记得带伞和充电器")]
        XCTAssertTrue(t.endIfAnswered(in: answered))
        XCTAssertNil(t.working)
        // Registered after the answer was logged: ends at once.
        t.expect(uttID: "inj-9")
        XCTAssertTrue(t.endIfAnswered(in: answered))
        XCTAssertNil(t.working)
        // A turn without utt_id is not ended by the log.
        t.expect(uttID: nil)
        XCTAssertFalse(t.endIfAnswered(in: answered))
        XCTAssertNotNil(t.working)
    }

    func testReceivedFromAnotherSourceStartsWorking() {
        var t = TurnState()
        t.handle(frame: ["type": "turn", "utt_id": "inj-1", "phase": "received", "text": "x"])
        XCTAssertEqual(t.working?.uttID, "inj-1")
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
            ImlogEntry(at: "2026-10-07T00:12:09.000Z", speaker: "多多", kind: "answer", text: "要带", truncated: true),
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
        let logged = OutboxItem(body: .text("a", attachments: []),
                                state: .delivered(uttID: "u1", at: nil, transcript: nil, recordAvailable: true))
        let queued = OutboxItem(body: .text("b", attachments: []))
        var turn = TurnState()
        turn.expect(uttID: "u2")
        let rows = ThreadBuilder(now: now, timeZone: tz).build(.init(
            entries: [ImlogEntry(at: "2026-10-07T03:00:00.000Z", kind: "typed", text: "a", utt_id: "u1")],
            outbox: [logged, queued], turn: turn, recordLost: ["u1"]))
        let pendingIDs = rows.compactMap { if case .pending(let p) = $0 { p.id } else { nil } }
        XCTAssertEqual(pendingIDs, [queued.id])
        guard case .working = rows.last else { return XCTFail() }
        guard case .mine(let m) = rows[1] else { return XCTFail() }
        XCTAssertEqual(m.delivery, "已送达，记录未保存")
    }
}

final class DuoduoAttachmentTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Shanghai")!

    /// The row the channel writes for files 多多 sent (`showBrainAttachments`), as `/live` and
    /// `/api/imlog` carry it.
    private let fileRowJSON = #"""
    {"type":"imlog_append","entries":[{"at":"2026-10-07T12:00:01.000Z","speaker":"多多","kind":"answer","text":"","attachments":[{"name":"示例图.png","mime":"image/png","sha256":"0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"},{"name":"report.pdf","mime":"application/pdf"}]}]}
    """#

    private func entries() throws -> [ImlogEntry] {
        let frame = try JSONSerialization.jsonObject(with: Data(fileRowJSON.utf8)) as! [String: Any]
        return ImlogEntry.decodeList(frame["entries"])
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
        let withLimit = Data(#"{"room":"study","room_name":"书房","date":"2026-10-07","daemon_ok":true,"cerebellum_ok":false,"capture":{"owner":null},"controls":{"mute":{"active":true}},"imlog":[{"at":"a","speaker":null,"kind":"typed","text":"hi","utt_id":"u1"}],"limits":{"upload_max_bytes":10485760}}"#.utf8)
        let s = RoomState.decode(withLimit)!
        XCTAssertEqual(s.uploadMaxBytes, 10_485_760)
        XCTAssertEqual(s.roomName, "书房")
        XCTAssertEqual(s.cerebellumOK, false)
        XCTAssertTrue(s.muted)
        XCTAssertEqual(s.imlog.first?.utt_id, "u1")
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

    func testUploadOutcomeAndInjectBody() throws {
        let ok = UploadPolicy.outcome(status: 200, body: Data(#"{"name":"a.jpg","mime":"image/jpeg","path":"/inbox/a.jpg","sha256":"ab"}"#.utf8),
                                      name: "a.jpg", mime: "image/jpeg", state: nil)
        guard case .uploaded(let a) = ok else { return XCTFail("\(ok)") }
        XCTAssertEqual(a.path, "/inbox/a.jpg")
        let body = ChannelPaths.injectBody(text: "看看", attachments: [a])
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual((obj["attachments"] as! [[String: Any]]).first?["path"] as? String, "/inbox/a.jpg")
        XCTAssertEqual(UploadPolicy.outcome(status: 503, body: Data(#"{"error":"bridge.upload_max_bytes must be a positive integer"}"#.utf8),
                                            name: "a", mime: "b", state: nil), .disabled)
        XCTAssertEqual(UploadPolicy.limitText(10_485_760), "文件太大（上限 10 MB）")
        XCTAssertEqual(UploadPolicy.limitText(1_572_864), "文件太大（上限 1.5 MB）")
    }

    func testPathsEscapeRoom() {
        XCTAssertEqual(ChannelPaths.state(room: "a&b"), "/api/state?room=a%26b")
        XCTAssertEqual(ChannelPaths.attachment(room: "r", ChannelAttachment(name: "报价 v2.pdf", mime: "application/pdf", sha256: "ff")),
                       "/api/attachment?room=r&sha256=ff&mime=application/pdf&name=%E6%8A%A5%E4%BB%B7%20v2.pdf")
    }
}
