// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import XCTest
@testable import PocketCore

final class VoiceNoteTests: XCTestCase {
    func testBodyEncoding() throws {
        let note = VoiceNote(source: .passport, packets: [Data([1, 2, 3]), Data(), Data(repeating: 9, count: 0x0101)])
        let body = try note.body()
        XCTAssertEqual([UInt8](body.prefix(5)), [3, 0, 1, 2, 3])
        XCTAssertEqual([UInt8](body[5..<7]), [0, 0])
        XCTAssertEqual([UInt8](body[7..<9]), [0x01, 0x01])
        XCTAssertEqual(body.count, 5 + 2 + 2 + 0x0101)
        XCTAssertEqual(try VoiceNote.packets(fromBody: body), note.packets)
    }

    func testTruncatedBodyIsRejected() {
        XCTAssertThrowsError(try VoiceNote.packets(fromBody: Data([5, 0, 1, 2]))) {
            XCTAssertEqual($0 as? VoiceNote.BodyError, .truncated(offset: 0))
        }
    }

    func testHeadersAndPath() {
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let h = VoiceUploader.headers(for: VoiceNote(id: id, source: .phone, packets: []))
        XCTAssertEqual(h["Content-Type"], "application/vnd.ambient.opus-packets")
        XCTAssertEqual(h["X-Voice-Id"], "6f9619ff-8b86-d011-b42d-00c04fc964ff")
        XCTAssertEqual(h["X-Voice-Source"], "phone")
        XCTAssertEqual(VoiceUploader.path(room: "study"), "/api/voice?room=study")
        XCTAssertEqual(VoiceUploader.path(room: "a&b c"), "/api/voice?room=a%26b%20c")
    }
}

final class PressAssemblerTests: XCTestCase {
    func completed(_ events: [PressAssembler.Event]) -> CompletedPress? {
        for e in events { if case .completed(let c) = e { return c } }
        return nil
    }

    func testOnePressOneNote() {
        var a = PressAssembler()
        XCTAssertEqual(a.handle(.pressStart(pressID: 1)), [.started(pressID: 1, implicit: false)])
        for s in 0..<50 { XCTAssertEqual(a.handle(.audio(pressID: 1, seq: UInt16(s), packet: Data([UInt8(s)]))), []) }
        XCTAssertEqual(a.handle(.keepalive(pressID: 1)), [])
        let c = completed(a.handle(.pressEnd(pressID: 1, packetCount: 50)))
        XCTAssertEqual(c?.packets.count, 50)
        XCTAssertEqual(c?.packets.first, Data([0]))
        XCTAssertEqual(c?.stats.declaredCount, 50)
        XCTAssertEqual(c?.stats.gaps, 0)
        XCTAssertEqual(c?.stats.end, .pressEnd)
        XCTAssertNil(a.activePressID)
        // A repeated PRESS_END delivers nothing.
        XCTAssertEqual(a.handle(.pressEnd(pressID: 1, packetCount: 50)), [])
    }

    func testGapsAndDuplicatesAreCounted() {
        var a = PressAssembler()
        _ = a.handle(.pressStart(pressID: 2))
        for s: UInt16 in [0, 1, 1, 4, 3, 5] { _ = a.handle(.audio(pressID: 2, seq: s, packet: Data([UInt8(s)]))) }
        let c = completed(a.handle(.pressEnd(pressID: 2, packetCount: 6)))
        XCTAssertEqual(c?.packets, [Data([0]), Data([1]), Data([4]), Data([5])])
        XCTAssertEqual(c?.stats.gaps, 2)
        XCTAssertEqual(c?.stats.duplicates, 2)
    }

    func testSequenceWraps() {
        var a = PressAssembler()
        _ = a.handle(.pressStart(pressID: 3))
        _ = a.handle(.audio(pressID: 3, seq: 0, packet: Data([0])))
        var s: UInt16 = 0
        for _ in 0..<70000 { s &+= 1; _ = a.handle(.audio(pressID: 3, seq: s, packet: Data([1]))) }
        let c = completed(a.handle(.pressEnd(pressID: 3, packetCount: 0)))
        XCTAssertEqual(c?.stats.packets, 70001)
        XCTAssertEqual(c?.stats.gaps, 0)
    }

    func testAudioWithoutPressStartStartsImplicitly() {
        var a = PressAssembler()
        XCTAssertEqual(a.handle(.audio(pressID: 9, seq: 120, packet: Data([1]))), [.started(pressID: 9, implicit: true)])
        let c = completed(a.handle(.pressEnd(pressID: 9, packetCount: 121)))
        XCTAssertEqual(c?.stats.implicitStart, true)
        XCTAssertEqual(c?.stats.gaps, 0)
    }

    func testNewPressSupersedesUnfinishedOne() {
        var a = PressAssembler()
        _ = a.handle(.pressStart(pressID: 1))
        _ = a.handle(.audio(pressID: 1, seq: 0, packet: Data([1])))
        let events = a.handle(.pressStart(pressID: 2))
        XCTAssertEqual(completed(events)?.stats.end, .superseded)
        XCTAssertEqual(events.last, .started(pressID: 2, implicit: false))
    }

    func testLinkLossDeliversPartialPress() {
        var a = PressAssembler()
        _ = a.handle(.pressStart(pressID: 4))
        _ = a.handle(.audio(pressID: 4, seq: 0, packet: Data([1])))
        let c = completed(a.linkLost())
        XCTAssertEqual(c?.stats.end, .linkLost)
        XCTAssertEqual(c?.packets.count, 1)
        XCTAssertEqual(a.linkLost(), [])
    }

    func testPressEndWithoutAudioIsAnEmptyPress() {
        var a = PressAssembler()
        let c = completed(a.handle(.pressEnd(pressID: 5, packetCount: 0)))
        XCTAssertEqual(c?.packets, [])
    }
}

/// Scripted transport: one response (or failure) per attempt.
final class FakeTransport: ChannelTransport, @unchecked Sendable {
    enum Step { case status(Int, String), fail(TransportFailure) }
    var steps: [Step]
    var seen: [(path: String, headers: [String: String], body: Data, timeout: TimeInterval)] = []

    init(_ steps: [Step]) { self.steps = steps }

    func send(method: String, path: String, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        seen.append((path, headers, body, timeout))
        let step = steps.isEmpty ? .fail(.network("exhausted")) : steps.removeFirst()
        switch step {
        case .status(let s, let b): return (s, Data(b.utf8))
        case .fail(let f): throw f
        }
    }
}

/// Virtual clock: sleeping advances time instantly.
final class FakeClock: @unchecked Sendable {
    var t: TimeInterval = 1000
    var sleeps: [TimeInterval] = []
}

final class VoiceUploaderTests: XCTestCase {
    let note = VoiceNote(source: .passport, packets: [Data([1, 2]), Data([3])])

    func uploader(_ t: FakeTransport, _ c: FakeClock, deadline: TimeInterval = 25) -> VoiceUploader {
        var tuning = PocketTuning()
        tuning.uploadDeadline = deadline
        return VoiceUploader(transport: t, tuning: tuning,
                             sleep: { c.sleeps.append($0); c.t += $0 },
                             now: { c.t })
    }

    func testSuccess() async {
        let t = FakeTransport([.status(200, #"{"voice_id":"x","text":"你好","utt_id":"u-42"}"#)])
        let r = await uploader(t, FakeClock()).upload(note, room: "study")
        XCTAssertEqual(r.outcome, .transcribed("你好", uttID: "u-42"))
        XCTAssertEqual(r.outcome.uttID, "u-42")
        XCTAssertEqual(r.attempts, 1)
        XCTAssertEqual(t.seen.first?.body, try note.body())
        XCTAssertEqual(t.seen.first?.path, "/api/voice?room=study")
    }

    func testRetriesKeepTheSameVoiceID() async {
        let t = FakeTransport([.fail(.network("reset")), .status(503, #"{"error":"cerebellum_unavailable"}"#),
                               .status(200, #"{"text":"ok"}"#)])
        let c = FakeClock()
        let r = await uploader(t, c).upload(note, room: "r")
        XCTAssertEqual(r.outcome, .transcribed("ok", uttID: nil))
        XCTAssertEqual(r.attempts, 3)
        XCTAssertEqual(Set(t.seen.map { $0.headers["X-Voice-Id"]! }).count, 1)
        XCTAssertEqual(Set(t.seen.map(\.body)).count, 1)
        XCTAssertEqual(c.sleeps, [0.5, 1.0])
    }

    func testFinalErrorsAreNotRetried() async {
        let cases: [(Int, String, VoiceOutcome)] = [
            (422, #"{"error":"empty_transcript"}"#, .empty),
            (502, #"{"error":"asr_failed"}"#, .asrFailed),
            (400, #"{"error":"bad_body"}"#, .sendFailed("400 bad_body")),
        ]
        for (status, body, want) in cases {
            let t = FakeTransport([.status(status, body), .status(200, "{}")])
            let r = await uploader(t, FakeClock()).upload(note, room: "r")
            XCTAssertEqual(r.outcome, want)
            XCTAssertEqual(r.attempts, 1)
            XCTAssertEqual(r.outcome.resultCode, [422: ResultCode.empty, 502: .asrFailed, 400: .sendFailed][status])
        }
    }

    func testDeadlineEndsRetries() async {
        let t = FakeTransport(Array(repeating: .fail(.notConnected("NeedsLogin")), count: 100))
        let c = FakeClock()
        let r = await uploader(t, c, deadline: 10).upload(note, room: "r")
        XCTAssertEqual(r.outcome, .notConnected("NeedsLogin"))
        XCTAssertEqual(r.outcome.resultCode, .notConnectedToServer)
        // 0.5 + 1 + 2 + 4 + 2.5 (cut at the deadline)
        XCTAssertEqual(c.sleeps, [0.5, 1, 2, 4, 2.5])
        XCTAssertEqual(r.attempts, 5)
        // Every attempt's timeout is the time left, never past the deadline.
        XCTAssertEqual(t.seen.map(\.timeout), [10, 9.5, 8.5, 6.5, 2.5])
    }

    func testServerErrorsAfterDeadlineReportSendFailed() async {
        let t = FakeTransport(Array(repeating: .status(500, "{}"), count: 100))
        let r = await uploader(t, FakeClock(), deadline: 1).upload(note, room: "r")
        XCTAssertEqual(r.outcome.resultCode, .sendFailed)
    }

    func testEmptyNoteIsNotUploaded() async {
        let t = FakeTransport([])
        let r = await uploader(t, FakeClock()).upload(VoiceNote(source: .passport, packets: []), room: "r")
        XCTAssertEqual(r.outcome, .empty)
        XCTAssertTrue(t.seen.isEmpty)
    }
}
