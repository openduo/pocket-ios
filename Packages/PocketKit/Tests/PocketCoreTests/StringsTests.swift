// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

@testable import PocketCore
import XCTest

final class StringsTests: XCTestCase {
    override func tearDown() { PocketStrings.language = .zhHans }

    func testEnglishText() {
        PocketStrings.language = .en
        XCTAssertEqual(TurnState.Trace(steps: [], elapsed: 75).summaryLine, "Done · 0 steps · 1 min 15 s")
        XCTAssertEqual(UploadPolicy.limitText(5 * 1_048_576), "File too large (limit 5.0 MB)")
        XCTAssertEqual(UploadPolicy.limitText(nil), "File too large")
        XCTAssertEqual(PocketStrings.monthDay(3, 9, "08:15"), "Mar 9, 08:15")
    }

    func testChineseIsTheDefault() {
        XCTAssertEqual(TurnState.Trace(steps: [], elapsed: 75).summaryLine, "任务已完成 · 0 步 · 1 分 15 秒")
        XCTAssertEqual(UploadPolicy.limitText(nil), "文件太大")
    }
}
