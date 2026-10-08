// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Device → phone messages (docs/ble-protocol.md §7).
public enum DeviceMessage: Equatable {
    case info(DeviceInfo)
    case pressStart(pressID: UInt16)
    case audio(pressID: UInt16, seq: UInt16, packet: Data)
    case pressEnd(pressID: UInt16, packetCount: UInt16)
    case status(battery: UInt8, charging: Charging)
    case keepalive(pressID: UInt16)

    public enum Kind: UInt8 {
        case info = 0x01, pressStart = 0x02, audio = 0x03, pressEnd = 0x04, status = 0x05, keepalive = 0x06
    }

    public enum DecodeError: Error, Equatable {
        case unknownType(UInt8)
        case malformed(UInt8)
    }

    public var kind: Kind {
        switch self {
        case .info: .info
        case .pressStart: .pressStart
        case .audio: .audio
        case .pressEnd: .pressEnd
        case .status: .status
        case .keepalive: .keepalive
        }
    }

    public func payload() -> Data {
        var w = ByteWriter()
        switch self {
        case .info(let i):
            w.u8(i.protoMajor)
            w.u8(i.protoMinor)
            let fw = Data(i.firmware.utf8.prefix(Int(UInt8.max)))
            w.u8(UInt8(fw.count))
            w.bytes(fw)
            w.u8(i.battery)
            w.u8(i.charging.rawValue)
            w.u8(i.preroll ? 1 : 0)
        case .pressStart(let id), .keepalive(let id):
            w.u16(id)
        case .audio(let id, let seq, let packet):
            w.u16(id)
            w.u16(seq)
            w.bytes(packet)
        case .pressEnd(let id, let count):
            w.u16(id)
            w.u16(count)
        case .status(let battery, let charging):
            w.u8(battery)
            w.u8(charging.rawValue)
        }
        return w.data
    }

    public static func decode(type: UInt8, payload: Data) throws -> DeviceMessage {
        guard let kind = Kind(rawValue: type) else { throw DecodeError.unknownType(type) }
        var r = ByteReader(payload)
        do {
            switch kind {
            case .info:
                let major = try r.u8(), minor = try r.u8()
                let fw = String(decoding: try r.bytes(Int(try r.u8())), as: UTF8.self)
                let battery = try r.u8(), charging = Charging(wire: try r.u8()), preroll = try r.u8()
                // Later minors append fields after these; they are ignored here.
                return .info(DeviceInfo(protoMajor: major, protoMinor: minor, firmware: fw,
                                        battery: battery, charging: charging, preroll: preroll != 0))
            case .pressStart: return .pressStart(pressID: try r.u16())
            case .audio:
                let id = try r.u16(), seq = try r.u16()
                return .audio(pressID: id, seq: seq, packet: r.rest())
            case .pressEnd:
                let id = try r.u16()
                return .pressEnd(pressID: id, packetCount: try r.u16())
            case .status:
                let b = try r.u8()
                return .status(battery: b, charging: Charging(wire: try r.u8()))
            case .keepalive: return .keepalive(pressID: try r.u16())
            }
        } catch is ByteReader.Failure {
            throw DecodeError.malformed(type)
        }
    }
}

/// Charging state on the wire (ble-protocol §7 item 2): 0 no, 1 yes, 0xFF unknown (the board may have no
/// charge-status signal). Any other value reads as unknown.
public enum Charging: UInt8, Equatable, Codable {
    case no = 0, yes = 1, unknown = 0xFF
    public init(wire: UInt8) { self = Charging(rawValue: wire) ?? .unknown }
}

/// INFO payload (ble-protocol §7 item 1). Wire order: proto_major u8, proto_minor u8, firmware version as
/// one length byte then UTF-8, battery % u8, charging u8, preroll u8. Later minors append fields.
public struct DeviceInfo: Equatable, Codable {
    public var protoMajor: UInt8
    public var protoMinor: UInt8
    public var firmware: String
    public var battery: UInt8
    public var charging: Charging
    public var preroll: Bool

    public init(protoMajor: UInt8, protoMinor: UInt8, firmware: String, battery: UInt8, charging: Charging, preroll: Bool) {
        self.protoMajor = protoMajor
        self.protoMinor = protoMinor
        self.firmware = firmware
        self.battery = battery
        self.charging = charging
        self.preroll = preroll
    }

    /// Majors must match; minors are additive.
    public var compatible: Bool { protoMajor == PocketConstants.protoMajor }
}

/// RESULT codes (ble-protocol §7).
public enum ResultCode: UInt8, Equatable, Codable {
    case transcribed = 0
    case empty = 1
    case asrFailed = 2
    case sendFailed = 3
    case notConnectedToServer = 4
}

/// APP_STATE values (ble-protocol §7).
public enum AppState: UInt8, Equatable {
    case ok = 0
    case serverUnreachable = 1
    /// Protocol major mismatch; the device shows it.
    case protocolMismatch = 2
}

/// The phone app's UI language, sent after APP_STATE's state (ble-protocol §7 item 9, 1.2).
public enum UILanguage: UInt8, Equatable, Sendable {
    case zhHans = 0
    case en = 1

    /// The language of a resolved localization: any Chinese → zhHans, anything else → en.
    public init(localization: String?) {
        self = (localization ?? "zh-Hans").lowercased().hasPrefix("zh") ? .zhHans : .en
    }
}

/// WORK phases (ble-protocol §7 item 8): what the brain is doing while a reply is pending.
public enum WorkPhase: UInt8, Equatable {
    case idle = 0
    case received = 1
    case thinking = 2
    case tool = 3
}

/// Phone → device messages (ble-protocol §7).
public enum PhoneMessage: Equatable {
    case result(pressID: UInt16, code: ResultCode, text: String)
    case reply(replyID: UInt32, final: Bool, text: String)
    case replyDone(replyID: UInt32)
    /// `language` nil sends no language byte (a 1.1 phone); decoded nil for a missing or unknown byte.
    case appState(AppState, language: UILanguage?)
    /// `label` is optional UTF-8 after the phase; empty in v1.
    case work(phase: WorkPhase, label: String)

    public enum Kind: UInt8 {
        case result = 0x81, reply = 0x82, replyDone = 0x83, appState = 0x84, work = 0x85
    }

    public enum DecodeError: Error, Equatable {
        case unknownType(UInt8)
        case malformed(UInt8)
    }

    public var kind: Kind {
        switch self {
        case .result: .result
        case .reply: .reply
        case .replyDone: .replyDone
        case .appState: .appState
        case .work: .work
        }
    }

    public func payload() -> Data {
        var w = ByteWriter()
        switch self {
        case .result(let id, let code, let text):
            w.u16(id)
            w.u8(code.rawValue)
            w.bytes(Data(text.utf8))
        case .reply(let id, let final, let text):
            w.u32(id)
            w.u8(final ? 1 : 0)
            w.bytes(Data(text.utf8))
        case .replyDone(let id):
            w.u32(id)
        case .appState(let s, let language):
            w.u8(s.rawValue)
            if let language { w.u8(language.rawValue) }
        case .work(let phase, let label):
            w.u8(phase.rawValue)
            w.bytes(Data(label.utf8))
        }
        return w.data
    }

    public static func decode(type: UInt8, payload: Data) throws -> PhoneMessage {
        guard let kind = Kind(rawValue: type) else { throw DecodeError.unknownType(type) }
        var r = ByteReader(payload)
        do {
            switch kind {
            case .result:
                let id = try r.u16()
                guard let code = ResultCode(rawValue: try r.u8()) else { throw DecodeError.malformed(type) }
                return .result(pressID: id, code: code, text: String(decoding: r.rest(), as: UTF8.self))
            case .reply:
                let id = try r.u32()
                let final = try r.u8() != 0
                return .reply(replyID: id, final: final, text: String(decoding: r.rest(), as: UTF8.self))
            case .replyDone: return .replyDone(replyID: try r.u32())
            case .appState:
                guard let s = AppState(rawValue: try r.u8()) else { throw DecodeError.malformed(type) }
                let rest = r.rest()
                return .appState(s, language: rest.first.flatMap(UILanguage.init(rawValue:)))
            case .work:
                guard let p = WorkPhase(rawValue: try r.u8()) else { throw DecodeError.malformed(type) }
                return .work(phase: p, label: String(decoding: r.rest(), as: UTF8.self))
            }
        } catch is ByteReader.Failure {
            throw DecodeError.malformed(type)
        }
    }

    /// The message as PDUs for an ATT value size, with REPLY text cut to fit the message bound.
    public func fragments(attPayload: Int, maxMessage: Int = PocketConstants.maxMessageBytes) throws -> [Data] {
        try LinkFragmenter.fragments(type: kind.rawValue, message: fitted(maxMessage: maxMessage).payload(),
                                     attPayload: attPayload, maxMessage: maxMessage)
    }

    /// REPLY and RESULT text longer than the device's message bound is cut at a character
    /// boundary and marked with "…". This affects the Passport screen only; the phone keeps and
    /// shows the full text.
    public func fitted(maxMessage: Int) -> PhoneMessage {
        // The text budget is the bound minus the fixed fields: reply_id u32 + final u8, or
        // press_id u16 + code u8.
        switch self {
        case .reply(let id, let final, let text):
            return .reply(replyID: id, final: final, text: Self.cut(text, bytes: maxMessage - 5))
        case .result(let id, let code, let text):
            return .result(pressID: id, code: code, text: Self.cut(text, bytes: maxMessage - 3))
        default:
            return self
        }
    }

    static func cut(_ text: String, bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        let mark = "…"
        let budget = limit - mark.utf8.count
        var used = 0
        var out = ""
        for ch in text {
            let n = String(ch).utf8.count
            if used + n > budget { break }
            out.append(ch)
            used += n
        }
        return out + mark
    }
}

/// Decodes ATT values into device messages: PDU decode, reassembly, message decode.
public struct DeviceLinkDecoder {
    private var reassembler: LinkReassembler

    public init(maxMessage: Int = PocketConstants.maxMessageBytes) {
        reassembler = LinkReassembler(maxMessage: maxMessage)
    }

    public mutating func push(_ value: Data) throws -> DeviceMessage? {
        let pdu = try LinkPDU.decode(value)
        guard let (type, payload) = try reassembler.push(pdu) else { return nil }
        return try DeviceMessage.decode(type: type, payload: payload)
    }

    public mutating func reset() { reassembler.reset() }
}

/// The device-side twin of `DeviceLinkDecoder`, used by the Passport simulator and tests.
public struct PhoneLinkDecoder {
    private var reassembler: LinkReassembler

    public init(maxMessage: Int = PocketConstants.maxMessageBytes) {
        reassembler = LinkReassembler(maxMessage: maxMessage)
    }

    public mutating func push(_ value: Data) throws -> PhoneMessage? {
        let pdu = try LinkPDU.decode(value)
        guard let (type, payload) = try reassembler.push(pdu) else { return nil }
        return try PhoneMessage.decode(type: type, payload: payload)
    }

    public mutating func reset() { reassembler.reset() }
}

extension DeviceMessage {
    public func fragments(attPayload: Int, maxMessage: Int = PocketConstants.maxMessageBytes) throws -> [Data] {
        try LinkFragmenter.fragments(type: kind.rawValue, message: payload(), attPayload: attPayload, maxMessage: maxMessage)
    }
}
