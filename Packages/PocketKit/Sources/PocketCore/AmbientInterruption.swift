// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

/// An audio-session interruption of ambient mode, from its start to the resume. Ambient mode
/// stays on through it; only the user turns it off.
///
/// iOS may end an interruption without `shouldResume` (for example after a long call while the
/// app was in the background). Ambient mode then stays paused until the app is in front, where
/// the mic may be taken again; the user is told with a local notification if the end came while
/// the app was not active.
public struct AmbientInterruption: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Not interrupted.
        case none
        /// Began; no end yet. The mic belongs to someone else (a call, Siri, an alarm).
        case ongoing
        /// Ended without `shouldResume`: stopped by the interruption, waiting for the front.
        case pendingResume
    }

    public enum Action: Equatable, Sendable {
        /// Restart capture through the resume path.
        case resume
        /// Post the "ambient mode was interrupted" notification.
        case notify
    }

    public private(set) var state = State.none

    public init() {}

    /// Capture is stopped, whether the interruption is ongoing or has ended.
    public var active: Bool { state != .none }

    /// An interruption began while ambient mode was on.
    public mutating func began() {
        state = .ongoing
    }

    /// The interruption ended. With `shouldResume`, or with the app in front, ambient resumes now;
    /// otherwise it waits for the front, and the user is told.
    public mutating func ended(shouldResume: Bool, appActive: Bool) -> Action? {
        guard state != .none else { return nil }
        if shouldResume || appActive { return .resume }
        guard state == .ongoing else { return nil }
        state = .pendingResume
        return .notify
    }

    /// The app came to the front. Resumes only an interruption that has ended: one still ongoing
    /// waits for its end (or the next activation), so a call in progress keeps the mic.
    public func becameActive() -> Action? {
        state == .pendingResume ? .resume : nil
    }

    /// Capture restarted, or the user turned ambient mode on or off.
    public mutating func clear() {
        state = .none
    }
}
