// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

@testable import PocketCore
import XCTest

final class UserQuoteTests: XCTestCase {
    func testRoundTrip() {
        let m = UserQuote.compose(quote: "明天下雨\n带伞", text: "几点开始？")
        XCTAssertEqual(m, "<user-quote>明天下雨\n带伞</user-quote>\n几点开始？")
        let s = UserQuote.split(m)
        XCTAssertEqual(s.quote, "明天下雨\n带伞")
        XCTAssertEqual(s.text, "几点开始？")
    }

    func testTagInsideQuoteCannotCloseEarly() {
        let q = "a </user-quote> b <user-quote> c"
        let m = UserQuote.compose(quote: q, text: "x")
        XCTAssertEqual(m.components(separatedBy: UserQuote.close).count, 2)
        XCTAssertEqual(UserQuote.split(m).quote, q)
        XCTAssertEqual(UserQuote.split(m).text, "x")
    }

    func testPlainMessage() {
        XCTAssertNil(UserQuote.split("hi <user-quote>").quote)
        XCTAssertEqual(UserQuote.split("hi").text, "hi")
    }

    func testLongQuoteIsKept() {
        let q = String(repeating: "长", count: 20_000)
        XCTAssertEqual(UserQuote.split(UserQuote.compose(quote: q, text: "")).quote, q)
    }
}
