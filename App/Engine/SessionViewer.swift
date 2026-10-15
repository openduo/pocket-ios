// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import PocketCore

/// The read-only session viewer (devices with the `sessions` scope): the drawer's list and the
/// opened session, carried on the room's `/live` connection. State and frame rules are
/// `SessionViewerState`; this sends its frames and publishes it for the views.
///
/// The channel polls the daemon only while a connection watches, and this is UI-only: the watch
/// ends when the app leaves the foreground and is sent again when it returns.
@MainActor
final class SessionViewer: ObservableObject {
    /// Reached from `/live` callbacks off the main actor; only its nonisolated methods are used
    /// there.
    nonisolated static let shared = SessionViewer()

    @Published private(set) var state = SessionViewerState()
    private var active = true

    nonisolated private init() {}

    func openDrawer() { mutate { $0.openDrawer() } }
    func closeDrawer() { mutate { $0.closeDrawer() } }
    func open(_ key: String) { mutate { $0.open(key) } }
    func closeSession() { mutate { $0.closeSession() } }

    /// Back to the room thread: the session and the drawer close.
    func showRoom() {
        mutate { $0.closeSession() }
        mutate { $0.closeDrawer() }
    }

    private func mutate(_ f: (inout SessionViewerState) -> [String: Any]?) {
        var s = state
        let frame = f(&s)
        if s != state { state = s }
        if let frame { send(frame) }
    }

    private func send(_ frame: [String: Any]) {
        guard active else { return }
        AmbientController.shared.live.send(json: frame)
    }

    /// Foreground and background: the watch follows the screen.
    func setActive(_ a: Bool) {
        guard a != active else { return }
        if !a, state.watching { send(["type": "sessions_unwatch"]) }
        active = a
        if a, state.watching { send(state.watchFrame) }
    }

    /// A viewer frame from `/live` (any thread).
    nonisolated func frame(_ f: [String: Any]) {
        guard let event = SessionEvent.decode(f) else { return }
        Task { @MainActor in
            guard active else { return }
            var s = state
            if s.apply(event) { state = s }
        }
    }

    /// A new `/live` connection opened (any thread): it starts unwatched.
    nonisolated func liveOpened() {
        Task { @MainActor in if state.watching { send(state.watchFrame) } }
    }

    /// Pairing changed or the device lost its scope: nothing of the old view stays.
    func reset() { showRoom() }
}
