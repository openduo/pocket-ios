// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import COpusShim
import Foundation
import Opus
import PocketCore

public struct OpusFailure: Error, Equatable, CustomStringConvertible {
    public let code: Int32
    public let call: String
    public var description: String { "\(call): \(String(cString: opus_strerror(code)))" }
}

/// Opus encoder with the wire settings (docs/ble-protocol.md §1): 16 kHz mono, 20 ms frames,
/// complexity 0, VBR, DTX off, FEC off. Bitrate is not fixed there and stays libopus's automatic
/// choice. Feed any number of 16-bit samples; every complete 20 ms frame becomes one packet.
public final class OpusVoiceEncoder {
    private let enc: OpaquePointer
    private var pending: [Int16] = []
    private var out = [UInt8](repeating: 0, count: 1275) // RFC 6716 maximum packet size

    public init() throws {
        var err: Int32 = 0
        guard let e = opus_encoder_create(Int32(PocketConstants.sampleRate), 1, OPUS_APPLICATION_VOIP, &err), err == OPUS_OK else {
            throw OpusFailure(code: err, call: "opus_encoder_create")
        }
        enc = e
        try set(POCKET_OPUS_SET_COMPLEXITY, 0, "complexity")
        try set(POCKET_OPUS_SET_VBR, 1, "vbr")
        try set(POCKET_OPUS_SET_DTX, 0, "dtx")
        try set(POCKET_OPUS_SET_INBAND_FEC, 0, "fec")
        try set(POCKET_OPUS_SET_SIGNAL, POCKET_OPUS_SIGNAL_VOICE, "signal")
        pending.reserveCapacity(PocketConstants.frameSamples * 2)
    }

    deinit { opus_encoder_destroy(enc) }

    private func set(_ req: Int32, _ value: Int32, _ name: String) throws {
        let r = pocket_opus_encoder_set(enc, req, value)
        if r != OPUS_OK { throw OpusFailure(code: r, call: "ctl \(name)") }
    }

    /// Current value of a control, for tests.
    public func get(_ req: Int32) -> Int32 {
        var v: Int32 = -1
        _ = pocket_opus_encoder_get(enc, req, &v)
        return v
    }

    /// Appends samples and returns the packets for every complete frame.
    public func push(_ samples: UnsafeBufferPointer<Int16>) throws -> [Data] {
        pending.append(contentsOf: samples)
        let n = PocketConstants.frameSamples
        var packets: [Data] = []
        var start = 0
        while pending.count - start >= n {
            let len = try pending.withUnsafeBufferPointer { p in
                try out.withUnsafeMutableBufferPointer { o in
                    let r = opus_encode(enc, p.baseAddress! + start, Int32(n), o.baseAddress!, Int32(o.count))
                    if r < 0 { throw OpusFailure(code: r, call: "opus_encode") }
                    return Int(r)
                }
            }
            packets.append(Data(out[0..<len]))
            start += n
        }
        if start > 0 { pending.removeFirst(start) }
        return packets
    }

    public func push(_ samples: [Int16]) throws -> [Data] {
        try samples.withUnsafeBufferPointer { try push($0) }
    }

    /// Drops a partial frame (end of a press: less than 20 ms of audio is not worth a packet).
    public func reset() { pending.removeAll(keepingCapacity: true) }
}

/// Decoder for ambient playback and tests.
public final class OpusVoiceDecoder {
    private let dec: OpaquePointer
    // 120 ms is the longest Opus frame (RFC 6716).
    private var pcm = [Int16](repeating: 0, count: PocketConstants.sampleRate * 120 / 1000)

    public init() throws {
        var err: Int32 = 0
        guard let d = opus_decoder_create(Int32(PocketConstants.sampleRate), 1, &err), err == OPUS_OK else {
            throw OpusFailure(code: err, call: "opus_decoder_create")
        }
        dec = d
    }

    deinit { opus_decoder_destroy(dec) }

    public func decode(_ packet: Data) throws -> [Int16] {
        let n = try packet.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Int32 in
            try pcm.withUnsafeMutableBufferPointer { o in
                let r = opus_decode(dec, b.bindMemory(to: UInt8.self).baseAddress, Int32(packet.count),
                                    o.baseAddress!, Int32(o.count), 0)
                if r < 0 { throw OpusFailure(code: r, call: "opus_decode") }
                return r
            }
        }
        return Array(pcm[0..<Int(n)])
    }
}
