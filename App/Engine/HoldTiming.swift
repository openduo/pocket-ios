// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Milestones of one hold-to-talk press, from the finger touching the glass to the first
/// waveform bar that moves. Logged once per press as `hold_timing` with milliseconds since the
/// touch, so the latency the user feels can be broken down on a device.
///
/// Marks come from the main thread (gesture, UI) and the audio tap thread, so the state is
/// behind a lock. The first mark of each name wins; nothing here allocates per audio buffer
/// after the first.
final class HoldTiming: @unchecked Sendable {
    static let shared = HoldTiming()

    private let lock = NSLock()
    private var origin: TimeInterval?
    private var marks: [String: Double] = [:]
    private var fields: [String: Any] = [:]

    /// Starts a press. `eventAge` is how long ago the touch happened (the gesture's event time
    /// against now), so `touch` is the hardware event, not the handler.
    func begin(eventAge: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        origin = now - max(0, eventAge)
        marks = ["touch": 0, "touch_down": max(0, eventAge) * 1000]
        // How long the touch took to reach the handler (UITouch.timestamp against now).
        fields = ["touch_age_ms": (max(0, eventAge) * 1000).rounded()]
        lock.unlock()
    }

    /// Records a milestone once per press. Cheap after the first call of a name. `uptime` is
    /// the moment on the `systemUptime` clock (the mach host clock); default now.
    func mark(_ name: String, uptime: TimeInterval? = nil) {
        let now = uptime ?? ProcessInfo.processInfo.systemUptime
        lock.lock()
        if let o = origin, marks[name] == nil { marks[name] = ((now - o) * 1000).rounded() }
        lock.unlock()
    }

    /// Whether a press is being timed and `name` is still missing (lets hot paths skip work).
    func wants(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return origin != nil && marks[name] == nil
    }

    func note(_ key: String, _ value: Any) {
        lock.lock()
        if origin != nil { fields[key] = value }
        lock.unlock()
    }

    /// Logs the press and stops timing.
    func end(_ outcome: String) {
        lock.lock()
        guard origin != nil else { lock.unlock(); return }
        var obj = fields
        for (k, v) in marks { obj[k + "_ms"] = v }
        obj["outcome"] = outcome
        origin = nil
        marks = [:]
        fields = [:]
        lock.unlock()
        AppLog.shared.log("hold_timing", obj)
    }
}
