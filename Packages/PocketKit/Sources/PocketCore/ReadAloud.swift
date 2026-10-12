// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Why a read aloud (`POST /api/speech`) did not play in full.
public enum ReadAloudFailure: Equatable, Sendable {
    /// 422 `nothing_to_speak`: only code, tables or images.
    case nothingToSpeak
    /// 413 `body_too_large`.
    case tooLong
    /// 502 `synthesis_failed`.
    case synthesisFailed
    /// 503 `cerebellum_unavailable`.
    case unavailable
    /// No response: the channel could not be reached.
    case notConnected
    /// The stream broke after audio had started: what played is not the whole text.
    case cut
    /// Any other status.
    case other(Int, String)

    /// The failure an error response names.
    public static func of(status: Int, error: String) -> ReadAloudFailure {
        switch (status, error) {
        case (422, "nothing_to_speak"): .nothingToSpeak
        case (413, _): .tooLong
        case (502, _): .synthesisFailed
        case (503, _): .unavailable
        default: .other(status, error)
        }
    }
}

/// Splits a streamed `[u16 LE length][opus packet]…` body into packets as bytes arrive. The
/// response of a read aloud uses the framing of a voice message body.
public struct PacketStream: Equatable, Sendable {
    private var buffer = Data()

    public init() {}

    /// The packets completed by `chunk`.
    public mutating func push(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var out: [Data] = []
        var at = buffer.startIndex
        while buffer.endIndex - at >= 2 {
            let n = Int(buffer[at]) | Int(buffer[at + 1]) << 8
            guard buffer.endIndex - at - 2 >= n else { break }
            out.append(Data(buffer[(at + 2)..<(at + 2 + n)]))
            at += 2 + n
        }
        buffer = Data(buffer[at...])
        return out
    }

    /// Bytes of a packet not yet complete; non-zero at the end of a stream means it was cut.
    public var partial: Int { buffer.count }
}
