// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

@testable import PocketCore
import XCTest

final class MarkMoodTests: XCTestCase {
    func testActiveMoodsAlwaysAnimate() {
        let active: [MarkMood] = [.listening, .hearing, .thinking, .speaking(aloud: true), .speaking(aloud: false)]
        for mood in active {
            XCTAssertTrue(mood.animates(on: .external), "\(mood)")
            XCTAssertTrue(mood.animates(on: .battery), "\(mood)")
        }
    }

    func testRestingMoodsAreStillOnBattery() {
        for mood in [MarkMood.idle, .unavailable] {
            XCTAssertTrue(mood.animates(on: .external), "\(mood)")
            XCTAssertFalse(mood.animates(on: .battery), "\(mood)")
        }
    }
}
