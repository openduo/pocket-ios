// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import COpusShim
import PocketCore
import PocketOpus
import XCTest

final class OpusVoiceTests: XCTestCase {
    func tone(_ n: Int) -> [Int16] {
        (0..<n).map { Int16(8000 * sin(2 * Double.pi * 440 * Double($0) / 16000)) }
    }

    func testContractSettings() throws {
        let e = try OpusVoiceEncoder()
        XCTAssertEqual(e.get(POCKET_OPUS_GET_COMPLEXITY), 0)
        XCTAssertEqual(e.get(POCKET_OPUS_GET_VBR), 1)
        XCTAssertEqual(e.get(POCKET_OPUS_GET_DTX), 0)
        XCTAssertEqual(e.get(POCKET_OPUS_GET_INBAND_FEC), 0)
    }

    func testOnePacketPer20msAndDecodable() throws {
        let e = try OpusVoiceEncoder()
        // 1 s in uneven chunks: 50 packets, partial frames carried over.
        var packets: [Data] = []
        let pcm = tone(16000)
        var i = 0
        for chunk in [100, 1000, 333, 7000, 7567] {
            packets += try e.push(Array(pcm[i..<(i + chunk)]))
            i += chunk
        }
        XCTAssertEqual(packets.count, 50)
        let d = try OpusVoiceDecoder()
        for p in packets {
            XCTAssertLessThanOrEqual(p.count, 1275)
            XCTAssertEqual(try d.decode(p).count, PocketConstants.frameSamples)
        }
        // The body round-trips through the voice-note encoding.
        let body = try VoiceNote(source: .phone, packets: packets).body()
        XCTAssertEqual(try VoiceNote.packets(fromBody: body), packets)
    }
}
