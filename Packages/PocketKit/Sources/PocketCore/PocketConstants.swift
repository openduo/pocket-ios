// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Fixed values. Each has its basis; docs/constants.md is the table of record.
public enum PocketConstants {
    /// Link protocol version this app speaks (docs/ble-protocol.md §7: majors must match, minors
    /// are additive).
    public static let protoMajor: UInt8 = 1
    /// Minor 1 adds WORK (ble-protocol §7 item 8); a minor-0 device ignores the unknown type.
    /// Minor 2 adds the language byte after APP_STATE (item 9); older devices ignore it.
    public static let protoMinor: UInt8 = 2

    /// The channel's client-API major this app speaks: the channel announces its own in
    /// `ready.api`, and a lower or absent value means the channel must be upgraded. It is raised
    /// only by an incompatible change to the channel's HTTP or `/live` contract.
    public static let clientAPIMajor = 1

    /// Primary service and characteristics (ble-protocol §4: one service, TX notify, RX write
    /// without response). The firmware uses the same values.
    public static let serviceUUID = "8BD90001-86C5-454B-B65B-3F16CFFB662F"
    public static let txCharacteristicUUID = "8BD90002-86C5-454B-B65B-3F16CFFB662F"
    public static let rxCharacteristicUUID = "8BD90003-86C5-454B-B65B-3F16CFFB662F"

    /// Largest reassembled link message, both directions (ble-protocol §6). The Passport
    /// (ESP32-C3, no PSRAM) keeps one reply; its firmware probe measured 26.9 KB minimum free heap,
    /// and 4 KiB is about 15 % of it. 4 KiB holds about 1,300 CJK characters, several 240×320
    /// screens. The largest device message is one Opus packet (RFC 6716: at most 1,275 bytes)
    /// plus 4 bytes.
    public static let maxMessageBytes = 4096

    /// Audio format (ble-protocol §1).
    public static let sampleRate = 16_000
    public static let frameMs = 20
    public static let frameSamples = sampleRate * frameMs / 1000

    /// Voice-note upload media type (ble-protocol §2).
    public static let voiceContentType = "application/vnd.ambient.opus-packets"

    /// REPLY_DONE id the app sends when it stops waiting without a reply (ble-protocol §7 item 5,
    /// §9: the brain went idle without answering, or the `/live` connection could not be restored).
    /// `ReplyTracker` never produces 0 as a real reply id.
    public static let noReplyID: UInt32 = 0
}

/// Operational values with no hard derivation. Defaults are listed with their basis in
/// docs/constants.md; each can be overridden from UserDefaults (key = property name with the
/// `tuning.` prefix) so trials change them without a rebuild.
public struct PocketTuning: Equatable, Sendable {
    /// Total time for one phone voice note's upload, across retries, and the per-request bound
    /// of attachment uploads. Basis: iOS grants a background task about 30 s (Apple
    /// documentation; on the iPhone XS Max probe `backgroundTimeRemaining` read "unbounded" right
    /// after a wake). 25 s keeps a margin before suspension.
    public var uploadDeadline: TimeInterval = 25
    /// Time from a Passport PRESS_END to its RESULT: the upload (202), recognition and the
    /// channel's `message cleaned` over `/live`. Past it RESULT is 3 (4 with `/live` down).
    /// Basis: the 25 s of `uploadDeadline`, kept until the accept + recognition + judge latency is
    /// measured; same background-task margin.
    public var resultDeadline: TimeInterval = 25
    /// First retry delay, doubled per retry up to `uploadBackoffMax`. Chosen, no data: the
    /// expected failure is a dead pooled connection after suspension, which an immediate fresh
    /// dial fixes; the backoff only spaces repeats of a real outage.
    public var uploadBackoffInitial: TimeInterval = 0.5
    public var uploadBackoffMax: TimeInterval = 4
    /// Bound on tsnet "Running" and on the `/live` dial after a wake. Basis: the iPhone
    /// XS Max probe measured wake → socket at 180-260 ms with a 2.1 s worst stall; a BLE event
    /// gives about 10 s of background time, so 8 s surfaces a hang as a logged error inside it.
    public var connectTimeout: TimeInterval = 8
    /// Ping bound for a `/live` connection that may be stale after suspension. Basis: the iPhone XS
    /// Max probe measured 2.1 s maximum latency.
    public var pingTimeout: TimeInterval = 3

    public init() {}

    public static func load(_ defaults: UserDefaults = .standard) -> PocketTuning {
        var t = PocketTuning()
        func read(_ key: String, _ value: inout TimeInterval) {
            if let n = defaults.object(forKey: "tuning." + key) as? NSNumber, n.doubleValue > 0 { value = n.doubleValue }
        }
        read("uploadDeadline", &t.uploadDeadline)
        read("resultDeadline", &t.resultDeadline)
        read("uploadBackoffInitial", &t.uploadBackoffInitial)
        read("uploadBackoffMax", &t.uploadBackoffMax)
        read("connectTimeout", &t.connectTimeout)
        read("pingTimeout", &t.pingTimeout)
        return t
    }
}
