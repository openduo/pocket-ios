// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

@testable import PocketCore
import XCTest

final class SurfaceTests: XCTestCase {
    func testDerive() {
        func display(_ fg: Bool, _ awake: Bool, _ passport: Bool) -> Surface.Display {
            Surface.derive(foreground: fg, keepAwake: awake, passportReady: passport, spoken: false).display
        }
        XCTAssertEqual(display(true, true, true), .phoneAwake)
        XCTAssertEqual(display(true, false, true), .phone)
        XCTAssertEqual(display(false, true, true), .passport)
        XCTAssertEqual(display(false, true, false), .later)
        XCTAssertTrue(Surface.derive(foreground: false, keepAwake: false, passportReady: false, spoken: true).spoken)
    }

    func testWireForms() {
        let s = Surface(display: .phoneAwake, spoken: true)
        XCTAssertEqual(s.headers, ["X-Ambient-Display": "phone_awake", "X-Ambient-Spoken": "1"])
        XCTAssertEqual(Surface(display: .passport, spoken: false).headers,
                       ["X-Ambient-Display": "passport", "X-Ambient-Spoken": "0"])
        XCTAssertEqual(s.frame["type"] as? String, "surface")
        XCTAssertEqual(s.frame["display"] as? String, "phone_awake")
        XCTAssertEqual(s.frame["spoken"] as? Bool, true)
    }

    func testMessageHeadersCarryTheSurface() {
        let s = Surface(display: .later, spoken: false)
        XCTAssertEqual(ChannelPaths.typedMessageHeaders(key: "k", surface: s)["X-Ambient-Display"], "later")
        let note = VoiceNote(source: .passport, packets: [])
        XCTAssertEqual(VoiceUploader.headers(for: note, surface: s)["X-Ambient-Spoken"], "0")
    }
}
