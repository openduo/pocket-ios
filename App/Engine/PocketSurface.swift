// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import PocketCore

/// The app's `Surface` now, read from lock-protected mirrors only, so any queue may call it.
enum PocketSurface {
    static func current() -> Surface {
        let ambient = AmbientController.shared.snapshot()
        let foreground = AppPhase.value != "background"
        // What `AmbientController.wantsAudio` asks for, less 静音: whether the phone will play it.
        let spoken = !ambient.interrupted && !ambient.silent
            && (ambient.isOn || (AudioPreferences.speakReplies && foreground))
        return Surface.derive(foreground: foreground,
                              keepAwake: AudioPreferences.keepAwake,
                              passportReady: PocketEngine.shared.snapshot().link == .ready,
                              spoken: spoken)
    }

    /// Something `current()` reads changed: the `/live` connection reports the new value.
    static func changed() { AmbientController.shared.reportSurface() }
}
