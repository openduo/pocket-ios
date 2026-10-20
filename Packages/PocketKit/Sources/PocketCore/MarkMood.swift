// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

/// What the 多多 mark shows (`LogoMark` in the app draws it).
public enum MarkMood: Equatable, Sendable {
    /// Online, nothing going on.
    case idle
    /// Ambient mode listening to the room.
    case listening
    /// The user is talking to it (hold to talk).
    case hearing
    /// Received, thinking, or running a tool.
    case thinking
    /// Answering: `aloud` when the answer is playing, else the text is streaming.
    case speaking(aloud: Bool)
    /// Offline, not set up, deaf, paused or failed.
    case unavailable

    /// Whether the mark runs its frame timer. Moods where something is happening always do; a
    /// resting mood (idle, unavailable) is one still frame on battery and moves only on external
    /// power. Reduce Motion is applied by the view on top of this.
    public func animates(on power: PowerSource) -> Bool {
        switch self {
        case .listening, .hearing, .thinking, .speaking: true
        case .idle, .unavailable: power == .external
        }
    }
}

/// Where the phone's power comes from, as far as the mark cares.
public enum PowerSource: Equatable, Sendable {
    /// Plugged in: charging or full.
    case external
    /// Unplugged, or the state is unknown.
    case battery
}
