// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Little-endian writer for wire payloads.
public struct ByteWriter {
    public private(set) var data = Data()
    public init() {}
    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { data.append(UInt8(v & 0xff)); data.append(UInt8(v >> 8)) }
    public mutating func u32(_ v: UInt32) { for i in 0..<4 { data.append(UInt8((v >> (8 * UInt32(i))) & 0xff)) } }
    public mutating func bytes(_ d: Data) { data.append(d) }
}

/// Little-endian reader. Every read checks bounds and throws instead of trapping:
/// payloads come from a radio.
public struct ByteReader {
    public enum Failure: Error, Equatable { case truncated(need: Int, have: Int) }
    private let data: Data
    public private(set) var offset: Int

    public init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }

    private mutating func take(_ n: Int) throws -> Data {
        guard remaining >= n else { throw Failure.truncated(need: n, have: remaining) }
        defer { offset += n }
        return data[offset..<(offset + n)]
    }

    public mutating func u8() throws -> UInt8 { try take(1).first! }

    public mutating func u16() throws -> UInt16 {
        let d = try take(2)
        return UInt16(d[d.startIndex]) | UInt16(d[d.startIndex + 1]) << 8
    }

    public mutating func u32() throws -> UInt32 {
        let d = try take(4)
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[d.startIndex + $1]) << (8 * UInt32($1)) }
    }

    public mutating func bytes(_ n: Int) throws -> Data { Data(try take(n)) }

    /// The rest of the payload.
    public mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return Data(data[offset..<data.endIndex])
    }
}
