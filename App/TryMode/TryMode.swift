// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// 先体验: the app runs against `TryChannel`, a scripted channel inside the app, instead of the
/// user's channel over Tailscale. Every screen and code path above the transport is the real one.
///
/// Nothing of it is kept: the flag lives in memory, the placeholder host and room live in the
/// launch-only argument domain, and the room cache goes to a temporary directory that is removed
/// on exit and on the next entry.
enum TryMode {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var on = false

    static var active: Bool {
        lock.lock(); defer { lock.unlock() }
        return on
    }

    /// Placeholder connection while trying; never written to the app's own defaults.
    static let host = "try.duoduo.local"
    static let room = "try"

    static var cacheBase: URL { FileManager.default.temporaryDirectory.appendingPathComponent("try-mode", isDirectory: true) }

    static func enter() {
        try? FileManager.default.removeItem(at: cacheBase)
        setOverrides(["channel.host": host, "channel.room": room, "channel.tls": false])
        lock.lock(); on = true; lock.unlock()
        TryChannel.shared.reset()
        AppLog.shared.log("try_mode", ["on": true])
    }

    static func exit() {
        lock.lock(); on = false; lock.unlock()
        TryChannel.shared.reset()
        setOverrides([:])
        try? FileManager.default.removeItem(at: cacheBase)
        AppLog.shared.log("try_mode", ["on": false])
    }

    /// The argument domain wins over stored settings and is not persisted.
    private static func setOverrides(_ values: [String: Any]) {
        let d = UserDefaults.standard
        var args = d.volatileDomain(forName: UserDefaults.argumentDomain)
        for k in ["channel.host", "channel.room", "channel.tls"] { args.removeValue(forKey: k) }
        args.merge(values) { _, new in new }
        d.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    }
}
