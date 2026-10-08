// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import XCTest
@testable import PocketCore

final class LinkPDUTests: XCTestCase {
    func testHeaderLayout() {
        let pdu = LinkPDU(type: 0x03, more: true, payload: Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual([UInt8](pdu.encoded()), [0x03, 0x01, 0x03, 0x00, 0xAA, 0xBB, 0xCC])
        XCTAssertEqual(try LinkPDU.decode(pdu.encoded()), pdu)
    }

    func testLengthIsLittleEndian() throws {
        let payload = Data(repeating: 7, count: 0x0102)
        let enc = LinkPDU(type: 0x82, more: false, payload: payload).encoded()
        XCTAssertEqual(enc[2], 0x02)
        XCTAssertEqual(enc[3], 0x01)
        XCTAssertEqual(try LinkPDU.decode(enc).payload.count, 0x0102)
    }

    func testDecodeRejectsShortAndMismatchedValues() {
        XCTAssertThrowsError(try LinkPDU.decode(Data([0x01, 0x00, 0x00]))) {
            XCTAssertEqual($0 as? LinkPDU.DecodeError, .short(3))
        }
        XCTAssertThrowsError(try LinkPDU.decode(Data([0x01, 0x00, 0x05, 0x00, 1, 2]))) {
            XCTAssertEqual($0 as? LinkPDU.DecodeError, .lengthMismatch(declared: 5, actual: 2))
        }
    }

    func testFragmentationRoundTrip() throws {
        let message = Data((0..<1000).map { UInt8($0 % 251) })
        for att in [20, 23, 100, 182, 244, 512] {
            let frags = try LinkFragmenter.fragments(type: 0x82, message: message, attPayload: att)
            XCTAssertTrue(frags.allSatisfy { $0.count <= att }, "att \(att)")
            XCTAssertEqual(frags.count, Int((Double(message.count) / Double(att - 4)).rounded(.up)))
            var r = LinkReassembler()
            var got: Data?
            for (i, f) in frags.enumerated() {
                let pdu = try LinkPDU.decode(f)
                XCTAssertEqual(pdu.more, i < frags.count - 1)
                if let m = try r.push(pdu) { got = m.payload }
            }
            XCTAssertEqual(got, message, "att \(att)")
        }
    }

    func testSingleFragmentAndEmptyMessage() throws {
        XCTAssertEqual(try LinkFragmenter.fragments(type: 0x84, message: Data([1]), attPayload: 20),
                       [Data([0x84, 0x00, 0x01, 0x00, 0x01])])
        XCTAssertEqual(try LinkFragmenter.fragments(type: 0x84, message: Data(), attPayload: 20),
                       [Data([0x84, 0x00, 0x00, 0x00])])
    }

    func testFragmenterBounds() {
        XCTAssertThrowsError(try LinkFragmenter.fragments(type: 1, message: Data([1]), attPayload: 4))
        XCTAssertThrowsError(try LinkFragmenter.fragments(type: 1, message: Data(count: 11), attPayload: 20, maxMessage: 10))
    }

    func testInterruptedFragmentsDropThePartialMessage() throws {
        // ble-protocol §6: fragments are consecutive; anything in between drops the partial message.
        let reply = Data(repeating: 0x41, count: 40)
        let fr = try LinkFragmenter.fragments(type: 0x82, message: reply, attPayload: 20)
        let state = LinkPDU(type: 0x84, more: false, payload: Data([1])).encoded()
        var r = LinkReassembler()
        var out: [(UInt8, Data)] = []
        for v in [fr[0], state, fr[1], fr[2]] + fr {
            if let m = try r.push(try LinkPDU.decode(v)) { out.append(m) }
        }
        // The interrupted message is dropped. The PDU header has no "first fragment" flag, so the
        // stray tail fragments read as a shorter message of their own (the type decoder rejects
        // or ignores it); the next whole message decodes.
        XCTAssertEqual(out.map(\.0), [0x84, 0x82, 0x82])
        XCTAssertEqual(out[1].1, Data(reply.dropFirst(16)))
        XCTAssertEqual(out[2].1, reply)
        XCTAssertEqual(r.interrupted, 1)
    }

    func testReassemblerDropsOversizeMessage() throws {
        var r = LinkReassembler(maxMessage: 8)
        XCTAssertNil(try r.push(LinkPDU(type: 1, more: true, payload: Data(count: 6))))
        XCTAssertThrowsError(try r.push(LinkPDU(type: 1, more: false, payload: Data(count: 6))))
        // The buffer was cleared: a fresh message of the same type decodes.
        XCTAssertEqual(try r.push(LinkPDU(type: 1, more: false, payload: Data([9])))?.payload, Data([9]))
    }
}

final class LinkMessageTests: XCTestCase {
    func roundTrip(_ m: DeviceMessage, att: Int = 23) throws -> DeviceMessage? {
        var d = DeviceLinkDecoder()
        var out: DeviceMessage?
        for f in try m.fragments(attPayload: att) { out = try d.push(f) ?? out }
        return out
    }

    func testDeviceMessagesRoundTrip() throws {
        let msgs: [DeviceMessage] = [
            .info(DeviceInfo(protoMajor: 1, protoMinor: 2, firmware: "pocket-0.3.1", battery: 87, charging: .yes, preroll: false)),
            .info(DeviceInfo(protoMajor: 1, protoMinor: 0, firmware: "", battery: 5, charging: .unknown, preroll: true)),
            .pressStart(pressID: 0xBEEF),
            .audio(pressID: 7, seq: 65535, packet: Data((0..<80).map { UInt8($0) })),
            .pressEnd(pressID: 7, packetCount: 3000),
            .status(battery: 12, charging: .no),
            .status(battery: 13, charging: .unknown),
            .keepalive(pressID: 9),
        ]
        for m in msgs { XCTAssertEqual(try roundTrip(m), m) }
    }

    func testInfoWireLayout() throws {
        let info = DeviceMessage.info(DeviceInfo(protoMajor: 1, protoMinor: 0, firmware: "v1", battery: 50, charging: .unknown, preroll: true))
        // ble-protocol §7 items 1-2: firmware is one length byte then UTF-8; charging 0xFF = unknown.
        XCTAssertEqual([UInt8](info.payload()), [1, 0, 2, 0x76, 0x31, 50, 0xFF, 1])
        // A later minor may append fields; they are ignored.
        var p = info.payload()
        p.append(contentsOf: [9, 9])
        XCTAssertEqual(try DeviceMessage.decode(type: 0x01, payload: p), info)
    }

    func testUnexpectedChargingValueReadsUnknown() throws {
        XCTAssertEqual(try DeviceMessage.decode(type: 0x05, payload: Data([40, 7])), .status(battery: 40, charging: .unknown))
    }

    func testAudioWireLayout() {
        let a = DeviceMessage.audio(pressID: 0x0102, seq: 0x0304, packet: Data([0xFF]))
        XCTAssertEqual([UInt8](a.payload()), [0x02, 0x01, 0x04, 0x03, 0xFF])
    }

    func testMalformedAndUnknown() {
        XCTAssertThrowsError(try DeviceMessage.decode(type: 0x02, payload: Data([1]))) {
            XCTAssertEqual($0 as? DeviceMessage.DecodeError, .malformed(0x02))
        }
        XCTAssertThrowsError(try DeviceMessage.decode(type: 0x7F, payload: Data())) {
            XCTAssertEqual($0 as? DeviceMessage.DecodeError, .unknownType(0x7F))
        }
    }

    func testPhoneMessagesRoundTrip() throws {
        let msgs: [PhoneMessage] = [
            .result(pressID: 3, code: .transcribed, text: "明天早上八点提醒我"),
            .result(pressID: 4, code: .empty, text: ""),
            .reply(replyID: 0xDEADBEEF, final: false, text: String(repeating: "多", count: 300)),
            .reply(replyID: 1, final: true, text: "好的"),
            .replyDone(replyID: 0xDEADBEEF),
            .appState(.serverUnreachable, language: .zhHans),
            .appState(.protocolMismatch, language: .en),
            .appState(.ok, language: nil),
            .work(phase: .received, label: ""),
            .work(phase: .tool, label: "查天气"),
            .work(phase: .idle, label: ""),
        ]
        for m in msgs {
            var d = PhoneLinkDecoder()
            var out: PhoneMessage?
            for f in try m.fragments(attPayload: 182) { out = try d.push(f) ?? out }
            XCTAssertEqual(out, m)
        }
    }

    func testReplyWireLayout() {
        XCTAssertEqual([UInt8](PhoneMessage.reply(replyID: 0x01020304, final: true, text: "a").payload()),
                       [0x04, 0x03, 0x02, 0x01, 1, 0x61])
        XCTAssertEqual([UInt8](PhoneMessage.result(pressID: 0x0201, code: .asrFailed, text: "").payload()), [0x01, 0x02, 2])
        // APP_STATE (ble-protocol §7 item 9): state u8, then the language byte (protocol 1.2).
        XCTAssertEqual([UInt8](PhoneMessage.appState(.protocolMismatch, language: .en).payload()), [2, 1])
        XCTAssertEqual([UInt8](PhoneMessage.appState(.ok, language: .zhHans).payload()), [0, 0])
        XCTAssertEqual([UInt8](PhoneMessage.appState(.ok, language: nil).payload()), [0])
        // WORK (ble-protocol §7 item 8): phase u8, then the optional UTF-8 label.
        XCTAssertEqual(PhoneMessage.work(phase: .thinking, label: "").kind.rawValue, 0x85)
        XCTAssertEqual([UInt8](PhoneMessage.work(phase: .thinking, label: "").payload()), [2])
        XCTAssertEqual([UInt8](PhoneMessage.work(phase: .tool, label: "a").payload()), [3, 0x61])
        XCTAssertThrowsError(try PhoneMessage.decode(type: 0x85, payload: Data([9])))
        XCTAssertThrowsError(try PhoneMessage.decode(type: 0x85, payload: Data()))
    }

    func testOversizeReplyIsCutAtCharacterBoundary() throws {
        let long = String(repeating: "答", count: 2000) // 6000 UTF-8 bytes
        let fitted = PhoneMessage.reply(replyID: 5, final: true, text: long).fitted(maxMessage: 4096)
        guard case .reply(_, _, let text) = fitted else { return XCTFail() }
        XCTAssertLessThanOrEqual(fitted.payload().count, 4096)
        XCTAssertTrue(text.hasSuffix("…"))
        XCTAssertTrue(text.dropLast().allSatisfy { $0 == "答" })
        XCTAssertNoThrow(try PhoneMessage.reply(replyID: 5, final: true, text: long).fragments(attPayload: 182))
    }

    func testAppStateLanguageCompatibility() throws {
        // A 1.1 phone sends no language byte; an unknown value or extra bytes leave it unset.
        XCTAssertEqual(try PhoneMessage.decode(type: 0x84, payload: Data([1])), .appState(.serverUnreachable, language: nil))
        XCTAssertEqual(try PhoneMessage.decode(type: 0x84, payload: Data([0, 7])), .appState(.ok, language: nil))
        XCTAssertEqual(try PhoneMessage.decode(type: 0x84, payload: Data([0, 1, 9])), .appState(.ok, language: .en))
        XCTAssertThrowsError(try PhoneMessage.decode(type: 0x84, payload: Data()))
        XCTAssertEqual(UILanguage(localization: "zh-Hans"), .zhHans)
        XCTAssertEqual(UILanguage(localization: "zh-Hant-TW"), .zhHans)
        XCTAssertEqual(UILanguage(localization: "en"), .en)
        XCTAssertEqual(UILanguage(localization: "fr"), .en)
        XCTAssertEqual(UILanguage(localization: nil), .zhHans)
        XCTAssertEqual(PocketConstants.protoMinor, 2)
    }
}
