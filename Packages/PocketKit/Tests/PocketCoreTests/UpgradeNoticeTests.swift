// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import XCTest
@testable import PocketCore

final class UpgradeNoticeTests: XCTestCase {
    func testMessagesResponse() {
        XCTAssertEqual(UpgradeNotice.of(status: 410, error: "update_required"), .appUpdate)
        XCTAssertEqual(UpgradeNotice.of(status: 404, error: ""), .channelUpgrade)
        XCTAssertNil(UpgradeNotice.of(status: 410, error: "gone"))
        for status in [202, 400, 413, 415, 500, 503] {
            XCTAssertNil(UpgradeNotice.of(status: status, error: "update_required"))
        }
    }

    func testReadyAPI() throws {
        func ready(_ json: String) throws -> LiveEvent.Ready {
            let f = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            guard case .ready(let r) = LiveEvent.decode(f) else { throw XCTSkip("not ready") }
            return r
        }
        XCTAssertEqual(UpgradeNotice.of(try ready(#"{"type":"ready","seq":3,"api":1}"#)), .channelUpgrade)
        XCTAssertNil(UpgradeNotice.of(try ready(#"{"type":"ready","seq":3,"api":2}"#)))
        XCTAssertNil(UpgradeNotice.of(try ready(#"{"type":"ready","seq":3,"api":3}"#)))
        XCTAssertEqual(UpgradeNotice.of(try ready(#"{"type":"ready","seq":3,"api":0}"#)), .channelUpgrade)
        XCTAssertEqual(UpgradeNotice.of(try ready(#"{"type":"ready","seq":3}"#)), .channelUpgrade)
    }

    func testCerebellumHaltProtocol() {
        let mismatch = RoomState.decode(Data(#"{"room":"r","cerebellum_ok":false,"cerebellum_halt":{"reason":"protocol","channel":2}}"#.utf8))
        XCTAssertEqual(mismatch?.cerebellumMismatch, true)
        let other = RoomState.decode(Data(#"{"room":"r","cerebellum_ok":false,"cerebellum_halt":{"reason":"unauthorized"}}"#.utf8))
        XCTAssertEqual(other?.cerebellumMismatch, false)
        XCTAssertEqual(RoomState.decode(Data(#"{"room":"r","cerebellum_halt":null}"#.utf8))?.cerebellumMismatch, false)
    }
}
