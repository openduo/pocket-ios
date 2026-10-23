// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import PocketCore
import XCTest

final class RedialBackoffTests: XCTestCase {
    func testDoublesFromOneSecondUpToTheCap() {
        var b = RedialBackoff()
        let pauses = (0..<8).map { _ in b.failed() }
        XCTAssertEqual(pauses, [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testSustainedOnlyOnceThePauseReachesTheCap() {
        var b = RedialBackoff()
        XCTAssertFalse(b.sustained)
        for _ in 0..<5 { _ = b.failed() }
        XCTAssertFalse(b.sustained, "1+2+4+8+16 s of failures is not yet sustained")
        _ = b.failed()
        XCTAssertTrue(b.sustained)
    }

    func testResetStartsAgainFromTheFirstPause() {
        var b = RedialBackoff()
        for _ in 0..<7 { _ = b.failed() }
        b.reset()
        XCTAssertFalse(b.sustained)
        XCTAssertEqual(b.failed(), 1)
    }

    func testManyFailuresStayAtTheCap() {
        var b = RedialBackoff()
        for _ in 0..<1000 { _ = b.failed() }
        XCTAssertEqual(b.failed(), 30)
    }
}
