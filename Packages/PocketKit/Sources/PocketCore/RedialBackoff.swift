// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Pauses between `/live` attempts while the connection is wanted and keeps failing: 1 s, then
/// doubling up to 30 s (docs/constants.md). A network path change, the app coming to the front, or
/// a press dials at once and starts again from the first pause; a success resets it too.
public struct RedialBackoff: Equatable, Sendable {
    public static let first: TimeInterval = 1
    public static let cap: TimeInterval = 30

    /// Failures since the last success or reset.
    public private(set) var failures = 0

    public init() {}

    /// One more attempt failed: the pause before the next.
    public mutating func failed() -> TimeInterval {
        failures += 1
        return Self.delay(after: failures)
    }

    /// The pause has reached the cap: the outage outlasted every shorter pause (about 31 s of
    /// failures). Ambient mode stops its microphone from here on.
    public var sustained: Bool { failures > 0 && Self.delay(after: failures) >= Self.cap }

    public mutating func reset() { failures = 0 }

    static func delay(after failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        // 2^n overflows nothing here: past the cap the exponent stops mattering.
        let n = min(failures - 1, 16)
        return min(first * pow(2, Double(n)), cap)
    }
}
