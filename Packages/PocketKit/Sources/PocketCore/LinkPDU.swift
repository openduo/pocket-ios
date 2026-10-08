// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// One PDU on the Passport link (docs/ble-protocol.md §6): `[type u8][flags u8][len u16 LE][payload]`.
/// One PDU per ATT value (one notification or one write). `flags bit0` = more fragments follow.
public struct LinkPDU: Equatable {
    public static let headerBytes = 4
    public static let flagMore: UInt8 = 0x01

    public var type: UInt8
    public var more: Bool
    public var payload: Data

    public init(type: UInt8, more: Bool, payload: Data) {
        self.type = type
        self.more = more
        self.payload = payload
    }

    public enum DecodeError: Error, Equatable {
        case short(Int)
        case lengthMismatch(declared: Int, actual: Int)
    }

    public func encoded() -> Data {
        var w = ByteWriter()
        w.u8(type)
        w.u8(more ? LinkPDU.flagMore : 0)
        w.u16(UInt16(payload.count))
        w.bytes(payload)
        return w.data
    }

    /// Decodes one ATT value. The declared length must match the value exactly: a PDU never
    /// shares an ATT value with another, so any difference means corruption.
    public static func decode(_ value: Data) throws -> LinkPDU {
        guard value.count >= headerBytes else { throw DecodeError.short(value.count) }
        var r = ByteReader(value)
        let type = try r.u8()
        let flags = try r.u8()
        let len = Int(try r.u16())
        let body = r.rest()
        guard body.count == len else { throw DecodeError.lengthMismatch(declared: len, actual: body.count) }
        return LinkPDU(type: type, more: flags & flagMore != 0, payload: body)
    }
}

/// Splits one message into PDUs that each fit one ATT value.
public enum LinkFragmenter {
    public enum Failure: Error, Equatable {
        case attTooSmall(Int)
        case messageTooLarge(Int, max: Int)
    }

    /// - Parameters:
    ///   - attPayload: the largest ATT value the link carries now (for phone writes,
    ///     `maximumWriteValueLength(for: .withoutResponse)`; it follows the negotiated MTU).
    ///   - maxMessage: the reassembly bound both ends agree on.
    public static func fragments(type: UInt8, message: Data, attPayload: Int,
                                 maxMessage: Int = PocketConstants.maxMessageBytes) throws -> [Data] {
        let room = attPayload - LinkPDU.headerBytes
        guard room > 0 else { throw Failure.attTooSmall(attPayload) }
        guard message.count <= maxMessage else { throw Failure.messageTooLarge(message.count, max: maxMessage) }
        if message.isEmpty { return [LinkPDU(type: type, more: false, payload: Data()).encoded()] }
        var out: [Data] = []
        var start = message.startIndex
        while start < message.endIndex {
            let end = min(start + room, message.endIndex)
            out.append(LinkPDU(type: type, more: end < message.endIndex, payload: Data(message[start..<end])).encoded())
            start = end
        }
        return out
    }
}

/// Reassembles messages from PDUs. Fragments of one message are consecutive (ble-protocol §6): a PDU
/// of another type, or an unfragmented PDU, arriving while a message is partial drops the
/// partial message and is then handled on its own.
public struct LinkReassembler {
    public enum Failure: Error, Equatable {
        case tooLarge(type: UInt8, size: Int)
    }

    public let maxMessage: Int
    private var partialType: UInt8?
    private var partial = Data()
    /// Partial messages dropped because something else came between their fragments.
    public private(set) var interrupted = 0

    public init(maxMessage: Int = PocketConstants.maxMessageBytes) {
        self.maxMessage = maxMessage
    }

    /// Feeds one PDU. Returns the completed message payload, or nil while fragments are pending.
    /// A message over `maxMessage` is dropped whole and reported.
    public mutating func push(_ pdu: LinkPDU) throws -> (type: UInt8, payload: Data)? {
        if let t = partialType, t != pdu.type {
            interrupted += 1
            reset()
        }
        let size = partial.count + pdu.payload.count
        guard size <= maxMessage else {
            reset()
            throw Failure.tooLarge(type: pdu.type, size: size)
        }
        if pdu.more {
            partialType = pdu.type
            partial.append(pdu.payload)
            return nil
        }
        if partialType == nil { return (pdu.type, pdu.payload) }
        partial.append(pdu.payload)
        let out = partial
        reset()
        return (pdu.type, out)
    }

    /// Drops a partial message (link lost).
    public mutating func reset() {
        partialType = nil
        partial = Data()
    }
}
