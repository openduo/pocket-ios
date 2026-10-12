// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import XCTest
@testable import PocketCore

final class ReadAloudTests: XCTestCase {
    func testFailures() {
        XCTAssertEqual(ReadAloudFailure.of(status: 422, error: "nothing_to_speak"), .nothingToSpeak)
        XCTAssertEqual(ReadAloudFailure.of(status: 422, error: "other"), .other(422, "other"))
        XCTAssertEqual(ReadAloudFailure.of(status: 413, error: "body_too_large"), .tooLong)
        XCTAssertEqual(ReadAloudFailure.of(status: 502, error: "synthesis_failed"), .synthesisFailed)
        XCTAssertEqual(ReadAloudFailure.of(status: 503, error: "cerebellum_unavailable"), .unavailable)
        XCTAssertEqual(ReadAloudFailure.of(status: 400, error: "bad_body"), .other(400, "bad_body"))
    }

    func testPacketStreamSplitsAcrossChunks() throws {
        let packets = [Data([1, 2, 3]), Data(), Data(repeating: 7, count: 300)]
        let body = try VoiceNote(source: .phone, packets: packets).body()
        var s = PacketStream()
        var out: [Data] = []
        // One byte at a time: every split point, including inside a length prefix.
        for b in body { out += s.push(Data([b])) }
        XCTAssertEqual(out, packets)
        XCTAssertEqual(s.partial, 0)
        var whole = PacketStream()
        XCTAssertEqual(whole.push(body), packets)
    }

    func testCutStreamLeavesAPartialPacket() throws {
        let body = try VoiceNote(source: .phone, packets: [Data([1, 2]), Data([3, 4, 5])]).body()
        var s = PacketStream()
        XCTAssertEqual(s.push(body.prefix(body.count - 1)), [Data([1, 2])])
        XCTAssertGreaterThan(s.partial, 0)
    }
}
