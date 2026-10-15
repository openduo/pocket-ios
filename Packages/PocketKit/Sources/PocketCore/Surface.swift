// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Where the user will read 多多's reply and whether the phone will play it, as the app sees itself.
/// The channel turns it into a line the brain reads before the user's input, so the reply fits
/// the screen it lands on. Every message carries the value at send time (`headers`); the `/live`
/// connection reports it on every change (`frame`), for room speech.
public struct Surface: Equatable, Sendable {
    public enum Display: String, Sendable {
        /// The app is in front with 保持屏幕常亮 on.
        case phoneAwake = "phone_awake"
        /// The app is in front; the screen may lock.
        case phone
        /// The app is not in front and the Passport is linked: its small screen shows the reply.
        case passport
        /// No screen now; the reply is read in the app later.
        case later
    }

    public var display: Display
    /// The phone will play the reply aloud.
    public var spoken: Bool

    public init(display: Display, spoken: Bool) {
        self.display = display
        self.spoken = spoken
    }

    /// `foreground` is any app phase but background: an inactive app (Control Center, the app
    /// switcher) is still on the screen.
    public static func derive(foreground: Bool, keepAwake: Bool, passportReady: Bool, spoken: Bool) -> Surface {
        let display: Display = foreground ? (keepAwake ? .phoneAwake : .phone) : (passportReady ? .passport : .later)
        return Surface(display: display, spoken: spoken)
    }

    public var headers: [String: String] {
        ["X-Ambient-Display": display.rawValue, "X-Ambient-Spoken": spoken ? "1" : "0"]
    }

    public var frame: [String: Any] { ["type": "surface", "display": display.rawValue, "spoken": spoken] }
}
