// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import XCTest
@testable import PocketCore

final class PlaybackStatsTests: XCTestCase {
    /// Frames arrive and are scheduled but nothing plays back: the log line must show it.
    func testScheduledButNeverPlayedIsVisible() {
        var s = PlaybackStats(speechID: "s000005", gen: 3)
        for _ in 0..<5 {
            s.frameReceived()
            s.scheduled(ms: 20)
        }
        let f = s.fields(why: "replaced")
        XCTAssertEqual(f["speech_id"] as? String, "s000005")
        XCTAssertEqual(f["why"] as? String, "replaced")
        XCTAssertEqual(f["frames"] as? Int, 5)
        XCTAssertEqual(f["scheduled"] as? Int, 5)
        XCTAssertEqual(f["scheduled_ms"] as? Int, 100)
        XCTAssertEqual(f["played"] as? Int, 0)
        XCTAssertEqual(f["played_ms"] as? Int, 0)
        XCTAssertNil(f["decode_error"])
    }

    func testOnlyTheFirstFailureAsksForItsOwnLogLine() {
        var s = PlaybackStats(speechID: "c-u1", gen: 1)
        XCTAssertTrue(s.decodeFailed("opus_decode: corrupted stream"))
        XCTAssertFalse(s.decodeFailed("opus_decode: buffer too small"))
        XCTAssertTrue(s.scheduleFailed())
        XCTAssertFalse(s.scheduleFailed())
        let f = s.fields(why: "stopped")
        XCTAssertEqual(f["decode_failures"] as? Int, 2)
        XCTAssertEqual(f["decode_error"] as? String, "opus_decode: corrupted stream")
        XCTAssertEqual(f["schedule_failures"] as? Int, 2)
    }

    func testPlaybackOfAnotherGenerationIsNotCounted() {
        var s = PlaybackStats(speechID: "c-u2", gen: 4)
        s.played(gen: 3, ms: 20) // tail of the previous speech
        s.played(gen: 4, ms: 20)
        s.played(gen: 4, ms: 40)
        XCTAssertEqual(s.playedBlocks, 2)
        XCTAssertEqual(s.playedMs, 60)
    }
}
