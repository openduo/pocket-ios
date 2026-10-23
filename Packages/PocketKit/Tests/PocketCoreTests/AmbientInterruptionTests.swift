// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

@testable import PocketCore
import XCTest

final class AmbientInterruptionTests: XCTestCase {
    func testEndWithShouldResumeResumesWithoutNotice() {
        var i = AmbientInterruption()
        i.began()
        XCTAssertTrue(i.active)
        XCTAssertEqual(i.ended(shouldResume: true, appActive: false), .resume)
        i.clear()
        XCTAssertFalse(i.active)
    }

    func testEndWithoutShouldResumeInBackgroundNotifiesAndWaitsForTheFront() {
        var i = AmbientInterruption()
        i.began()
        XCTAssertEqual(i.ended(shouldResume: false, appActive: false), .notify)
        XCTAssertEqual(i.state, .pendingResume)
        XCTAssertTrue(i.active)
        XCTAssertEqual(i.becameActive(), .resume)
    }

    func testEndWithoutShouldResumeInFrontResumesNow() {
        var i = AmbientInterruption()
        i.began()
        XCTAssertEqual(i.ended(shouldResume: false, appActive: true), .resume)
    }

    func testActivationDuringAnOngoingInterruptionWaitsForItsEnd() {
        var i = AmbientInterruption()
        i.began()
        XCTAssertNil(i.becameActive())
        XCTAssertEqual(i.state, .ongoing)
        XCTAssertEqual(i.ended(shouldResume: false, appActive: true), .resume)
    }

    func testRepeatedEndNotifiesOnce() {
        var i = AmbientInterruption()
        i.began()
        XCTAssertEqual(i.ended(shouldResume: false, appActive: false), .notify)
        XCTAssertNil(i.ended(shouldResume: false, appActive: false))
    }

    func testNewInterruptionWhilePendingNotifiesAgain() {
        var i = AmbientInterruption()
        i.began()
        _ = i.ended(shouldResume: false, appActive: false)
        i.began()
        XCTAssertNil(i.becameActive())
        XCTAssertEqual(i.ended(shouldResume: false, appActive: false), .notify)
    }

    func testNothingWithoutAnInterruption() {
        var i = AmbientInterruption()
        XCTAssertNil(i.ended(shouldResume: true, appActive: true))
        XCTAssertNil(i.becameActive())
    }

    func testUserOffClearsAPendingResume() {
        var i = AmbientInterruption()
        i.began()
        _ = i.ended(shouldResume: false, appActive: false)
        i.clear()
        XCTAssertNil(i.becameActive())
        XCTAssertNil(i.ended(shouldResume: false, appActive: false))
    }
}
