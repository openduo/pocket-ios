// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Per-speech downlink counters, so a silent speech always leaves a log line saying where the
/// audio stopped: received, decoded, scheduled, played back.
///
/// Counted per packet on the controller's queue (O(1)); logged once per drain and once when the
/// speech ends, never per packet.
public struct PlaybackStats: Equatable {
    public let speechID: String
    /// The `AmbientEdge` generation the speech was declared under. Callbacks from another
    /// generation belong to another speech and are not counted.
    public let gen: Int

    public private(set) var frames = 0
    public private(set) var decodeFailures = 0
    public private(set) var scheduled = 0
    public private(set) var scheduledMs = 0.0
    public private(set) var scheduleFailures = 0
    public private(set) var playedBlocks = 0
    public private(set) var playedMs = 0.0
    public private(set) var firstDecodeError: String?

    public init(speechID: String, gen: Int) {
        self.speechID = speechID
        self.gen = gen
    }

    public mutating func frameReceived() { frames += 1 }

    /// Returns true for the first failure of this speech (the one worth its own log line).
    public mutating func decodeFailed(_ error: String) -> Bool {
        decodeFailures += 1
        guard firstDecodeError == nil else { return false }
        firstDecodeError = error
        return true
    }

    public mutating func scheduled(ms: Double) {
        scheduled += 1
        scheduledMs += ms
    }

    /// Returns true for the first failure of this speech.
    public mutating func scheduleFailed() -> Bool {
        scheduleFailures += 1
        return scheduleFailures == 1
    }

    /// One block of generation `g` played back. Other generations are ignored.
    public mutating func played(gen g: Int, ms: Double) {
        guard g == gen else { return }
        playedBlocks += 1
        playedMs += ms
    }

    /// Log fields; `why` says what ended or paused the speech.
    public func fields(why: String) -> [String: Any] {
        var f: [String: Any] = [
            "speech_id": speechID, "why": why, "frames": frames, "decode_failures": decodeFailures,
            "scheduled": scheduled, "scheduled_ms": Int(scheduledMs.rounded()),
            "schedule_failures": scheduleFailures, "played": playedBlocks, "played_ms": Int(playedMs.rounded()),
        ]
        if let firstDecodeError { f["decode_error"] = firstDecodeError }
        return f
    }
}
