// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import XCTest
@testable import PocketCore

final class PairingTests: XCTestCase {
    func testParsesLink() {
        let l = PairingLink.parse("duoduopocket://pair?host=box.example.ts.net&port=8443&tls=0&code=AB12-CD34")
        XCTAssertEqual(l, PairingLink(host: "box.example.ts.net", port: 8443, tls: false, code: "AB12-CD34"))
        XCTAssertEqual(PairingLink.parse("duoduopocket://pair?host=h&port=443&tls=1&code=c")?.tls, true)
    }

    func testParsesLinkInsidePastedText() {
        let text = "在手机上打开：\nduoduopocket://pair?host=h.example&port=443&tls=1&code=x%2By 十分钟内有效"
        XCTAssertEqual(PairingLink.parse(text), PairingLink(host: "h.example", port: 443, tls: true, code: "x+y"))
        XCTAssertEqual(PairingLink.parse("「duoduopocket://pair?host=h&code=c」")?.code, "c")
    }

    func testDefaultsPortAndTLS() {
        XCTAssertEqual(PairingLink.parse("DuoDuoPocket://PAIR?host=h&code=c"), PairingLink(host: "h", port: 443, tls: true, code: "c"))
    }

    func testRejectsBadLinks() {
        for s in ["", "https://example.com/pair?host=h&code=c", "duoduopocket://share",
                  "duoduopocket://pair?host=h", "duoduopocket://pair?code=c", "duoduopocket://pair?host=&code=c",
                  "duoduopocket://pair?host=h&code=c&port=0", "duoduopocket://pair?host=h&code=c&port=70000",
                  "duoduopocket://pair?host=h&code=c&port=x", "duoduopocket://pair?host=h&code=c&tls=maybe"] {
            XCTAssertNil(PairingLink.parse(s), s)
        }
    }

    func testIsPairURL() throws {
        XCTAssertTrue(PairingLink.isPairURL(try XCTUnwrap(URL(string: "duoduopocket://pair?code=x"))))
        XCTAssertFalse(PairingLink.isPairURL(try XCTUnwrap(URL(string: "duoduopocket://share"))))
        XCTAssertFalse(PairingLink.isPairURL(try XCTUnwrap(URL(string: "https://pair"))))
    }

    func testRequestBodyHasCodeOnly() throws {
        let body = PairingLink(host: "h", port: 443, tls: true, code: "c1").requestBody
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(o.count, 1)
        XCTAssertEqual(o["code"] as? String, "c1")
    }

    func testPairOutcome() {
        let ok = #"{"device_id":"d1","name":"iPhone","room":"study","room_name":"书房","scope":"sessions","token":"t"}"#
        XCTAssertEqual(PairOutcome.of(status: 200, body: Data(ok.utf8)),
                       .paired(PairedDevice(deviceID: "d1", name: "iPhone", room: "study", roomName: "书房", scope: .sessions, token: "t")))
        let noName = #"{"device_id":"d1","name":"n","room":"study","room_name":"","scope":"room","token":"t"}"#
        if case .paired(let d) = PairOutcome.of(status: 200, body: Data(noName.utf8)) {
            XCTAssertEqual(d.roomName, "study")
            XCTAssertEqual(d.scope, .room)
        } else {
            XCTFail("not paired")
        }
        XCTAssertEqual(PairOutcome.of(status: 401, body: Data(#"{"error":"invalid_code"}"#.utf8)), .invalidCode)
        XCTAssertEqual(PairOutcome.of(status: 400, body: Data(#"{"error":"invalid_code"}"#.utf8)), .invalidCode)
        XCTAssertEqual(PairOutcome.of(status: 400, body: Data(#"{"error":"bad_body"}"#.utf8)), .failed("400 bad_body"))
        XCTAssertEqual(PairOutcome.of(status: 404, body: Data()), .channelTooOld)
        XCTAssertEqual(PairOutcome.of(status: 404, body: Data(#"{"error":"not_found"}"#.utf8)), .channelTooOld)
        // A cookie-mode result has no token; a native client cannot use it.
        let cookie = #"{"device_id":"d1","name":"n","room":"r","room_name":"r","scope":"room"}"#
        XCTAssertEqual(PairOutcome.of(status: 200, body: Data(cookie.utf8)), .failed("malformed pair result"))
        let badScope = #"{"device_id":"d1","name":"n","room":"r","room_name":"r","scope":"all","token":"t"}"#
        XCTAssertEqual(PairOutcome.of(status: 200, body: Data(badScope.utf8)), .failed("malformed pair result"))
    }

    func testNeedsToken() {
        XCTAssertFalse(DeviceAuth.needsToken(path: "/healthz"))
        XCTAssertFalse(DeviceAuth.needsToken(path: "/api/pair"))
        for p in ["/api/messages?room=r", "/api/state?room=r", "/live?since=1&audio=0", "/api/upload?name=a",
                  "/api/speech", "/api/pairing", "/healthz2"] {
            XCTAssertTrue(DeviceAuth.needsToken(path: p), p)
        }
    }

    func testUnauthorized() {
        XCTAssertEqual(DeviceAuth.headers(token: "abc"), ["Authorization": "Bearer abc"])
        XCTAssertTrue(DeviceAuth.isUnauthorized(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8)))
        XCTAssertFalse(DeviceAuth.isUnauthorized(status: 401, body: Data(#"{"error":"invalid_code"}"#.utf8)))
        XCTAssertFalse(DeviceAuth.isUnauthorized(status: 403, body: Data(#"{"error":"unauthorized"}"#.utf8)))
        XCTAssertFalse(DeviceAuth.isUnauthorized(status: 401, body: Data("nope".utf8)))
        XCTAssertTrue(DeviceAuth.isUnauthorizedClose("close StatusCode(4401): failed to get reader: received close frame: status = StatusCode(4401) and reason = \"unauthorized\""))
        XCTAssertFalse(DeviceAuth.isUnauthorizedClose("close StatusPolicyViolation: room required"))
        XCTAssertFalse(DeviceAuth.isUnauthorizedClose("EOF"))
        XCTAssertTrue(DeviceAuth.isUnauthorizedOpenError("tsbridge: live unauthorized: expected handshake response status code 101 but got 401"))
        XCTAssertFalse(DeviceAuth.isUnauthorizedOpenError("dial tcp: i/o timeout"))
    }
}
