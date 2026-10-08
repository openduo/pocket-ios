// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Where a voice note was recorded (`X-Voice-Source`, docs/ble-protocol.md §2).
public enum VoiceSource: String, Codable, Sendable {
    case passport
    case phone
}

/// One press worth of Opus packets, uploaded whole (ble-protocol §2).
public struct VoiceNote: Equatable, Sendable {
    /// Idempotency key: the same id on every retry of this note.
    public let id: UUID
    public let source: VoiceSource
    public let packets: [Data]

    public init(id: UUID = UUID(), source: VoiceSource, packets: [Data]) {
        self.id = id
        self.source = source
        self.packets = packets
    }

    public enum BodyError: Error, Equatable {
        case packetTooLarge(index: Int, size: Int)
        case truncated(offset: Int)
    }

    /// Body: `[u16 LE length][packet bytes]` per packet, in capture order.
    public func body() throws -> Data {
        var w = ByteWriter()
        for (i, p) in packets.enumerated() {
            guard p.count <= Int(UInt16.max) else { throw BodyError.packetTooLarge(index: i, size: p.count) }
            w.u16(UInt16(p.count))
            w.bytes(p)
        }
        return w.data
    }

    /// Inverse of `body()`; reads back a voice note the outbox saved.
    public static func packets(fromBody body: Data) throws -> [Data] {
        var r = ByteReader(body)
        var out: [Data] = []
        while r.remaining > 0 {
            let at = r.offset - body.startIndex
            do {
                let n = Int(try r.u16())
                out.append(try r.bytes(n))
            } catch {
                throw BodyError.truncated(offset: at)
            }
        }
        return out
    }

    /// Audio duration at the wire frame length (ble-protocol §1).
    public var durationMs: Int { packets.count * PocketConstants.frameMs }
}
