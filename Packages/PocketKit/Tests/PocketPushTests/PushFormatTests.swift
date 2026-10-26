// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import XCTest
@testable import PocketPush

final class PushFormatTests: XCTestCase {
    /// Sealed by the channel's own code (`packages/channel-ambient/src/server/push.ts`), key 0...31.
    let key = Data((0..<32).map { UInt8($0) })
    let sealed = Data(base64Encoded: "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")!
    let text = " 好的，明天 八点 👨‍👩‍👧\n"

    func testOpensWhatTheChannelSealed() throws {
        let m = try XCTUnwrap(PushFormat.open(key: key, sealed: sealed))
        XCTAssertEqual(m, PushMessage(v: 1, room: "pocket", seq: 1_761_300_000_123, messageIDs: ["m2", "m1"],
                                      text: text, cut: false))
    }

    func testComputesTheChannelsIdentifiers() {
        XCTAssertEqual(PushFormat.answerID(key: key, messageIDs: ["m1", "m2"], text: text),
                       "3bbb33c36c1985a5b2bb22b433475381f7cee0fb1a6ab085c697bbceadeaf94f")
        XCTAssertEqual(PushFormat.threadID(key: key, room: "pocket"),
                       "fd010d9df4869be296cfa39b51bdd39923827582508250132dc7c5398cf853f1")
    }

    func testRefusesAnotherKeyAndTampering() {
        var other = key
        other[0] ^= 1
        XCTAssertNil(PushFormat.open(key: other, sealed: sealed))
        var bad = sealed
        bad[40] ^= 1
        XCTAssertNil(PushFormat.open(key: key, sealed: bad))
        XCTAssertNil(PushFormat.open(key: key, sealed: sealed.prefix(100)))
    }

    func testTrimsLikeJavaScript() {
        XCTAssertEqual(PushFormat.trim("\u{FEFF} a b\n\u{3000}"), "a b")
        XCTAssertEqual(PushFormat.trim("\u{85}a"), "\u{85}a")
        XCTAssertEqual(PushFormat.trim(" \n "), "")
    }
}

final class PushLedgerTests: XCTestCase {
    func message(_ seq: Int, room: String = "pocket") -> PushMessage {
        PushMessage(v: 1, room: room, seq: seq, messageIDs: [], text: "t", cut: false)
    }

    func testAlertsOnceAndQuietlyForWhatTheAppAlreadyShowed() {
        var l = PushLedger(room: "pocket")
        l.notified.insert("local")
        XCTAssertEqual(l.admit(message(10), id: "local"), .quiet)
        XCTAssertEqual(l.admit(message(11), id: "new"), .alert)
        XCTAssertEqual(l.admit(message(11), id: "new"), .replay, "a replayed push does not ring again")
    }

    func testOutOfOrderPushesStillAlertButReadRowsDoNot() {
        var l = PushLedger(room: "pocket")
        XCTAssertEqual(l.admit(message(20), id: "b"), .alert)
        XCTAssertEqual(l.admit(message(19), id: "a"), .alert)
        l.read(upTo: 20)
        XCTAssertEqual(l.pushed, [])
        XCTAssertEqual(l.admit(message(18), id: "old"), .quiet)
        XCTAssertEqual(l.admit(message(21), id: "c"), .alert)
    }

    func testCountsEachShownAnswerOnceUntilRead() {
        var l = PushLedger(room: "pocket")
        XCTAssertTrue(l.notice("local"))
        XCTAssertFalse(l.notice("local"))
        XCTAssertEqual(l.admit(message(10), id: "local"), .quiet)
        XCTAssertEqual(l.unread, 1, "the push of an answer the app showed does not count again")
        XCTAssertEqual(l.admit(message(11), id: "new"), .alert)
        XCTAssertEqual(l.admit(message(11), id: "new"), .replay)
        XCTAssertEqual(l.admit(message(12, room: "desk"), id: "x"), .foreign)
        XCTAssertEqual(l.unread, 2)
        l.read(upTo: 11)
        XCTAssertEqual(l.unread, 0)
        XCTAssertEqual(l.admit(message(9), id: "old"), .quiet)
        XCTAssertEqual(l.unread, 0)
    }

    func testDecodesALedgerWrittenBeforeTheBadge() throws {
        let old = #"{"room":"pocket","notified":["a"],"readSeq":7,"pushed":[8]}"#
        let l = try JSONDecoder().decode(PushLedger.self, from: Data(old.utf8))
        XCTAssertEqual(l.room, "pocket")
        XCTAssertEqual(l.notified, ["a"])
        XCTAssertEqual(l.readSeq, 7)
        XCTAssertEqual(l.pushed, [8])
        XCTAssertEqual(l.unread, 0)
    }

    func testAnotherRoomIsForeign() {
        var l = PushLedger(room: "pocket")
        XCTAssertEqual(l.admit(message(5, room: "desk"), id: "x"), .foreign)
    }
}
