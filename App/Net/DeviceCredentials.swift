// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import PocketCore
import Security

/// The device token from pairing, and whether the channel has rejected it. The token lives in
/// the Keychain; the bridge sends it with every request and the `/live` upgrade to the host it
/// belongs to (`Tailnet.apply`). A rejection (401 `unauthorized`, `/live` close 4401) stops
/// reconnecting until the user pairs again.
final class DeviceCredentials: @unchecked Sendable {
    static let shared = DeviceCredentials()

    private let lock = NSLock()
    private var cached: String?
    /// Kept across launches, so a relaunch does not retry with a dead token. Not secret.
    private var rejected = UserDefaults.standard.bool(forKey: rejectedKey)
    private static let rejectedKey = "device.rejected"
    /// Called on any thread after the token or the rejection changed.
    var onChange: (() -> Void)?

    /// The stored token. Read lazily: before the first unlock after a reboot the Keychain item is
    /// not readable, and a later read succeeds.
    var token: String? {
        lock.lock(); defer { lock.unlock() }
        if cached == nil { cached = Keychain.read() }
        return cached
    }

    /// The channel rejected the token; only pairing again helps. Never in 先体验, which needs no
    /// token.
    var unauthorized: Bool {
        lock.lock(); defer { lock.unlock() }
        return rejected && !TryMode.active
    }

    func store(_ token: String) {
        Keychain.write(token)
        lock.lock()
        cached = token
        rejected = false
        UserDefaults.standard.removeObject(forKey: Self.rejectedKey)
        lock.unlock()
        onChange?()
    }

    func reportUnauthorized(_ source: String) {
        guard !TryMode.active else { return }
        lock.lock()
        let first = !rejected
        rejected = true
        if first { UserDefaults.standard.set(true, forKey: Self.rejectedKey) }
        lock.unlock()
        guard first else { return }
        AppLog.shared.log("device_unauthorized", ["source": source])
        onChange?()
    }

    /// One generic-password item. Readable after the first unlock so a Passport press in the
    /// background can still reach the channel; never synced to other devices.
    private enum Keychain {
        static let service = "dev.openduo.pocket.device"
        static let account = "token"

        static var query: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
             kSecAttrAccount as String: account]
        }

        static func read() -> String? {
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }

        static func write(_ token: String) {
            let data = Data(token.utf8)
            let attrs: [String: Any] = [kSecValueData as String: data,
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil)
            }
            if status != errSecSuccess { AppLog.shared.log("keychain_write_error", ["status": Int(status)]) }
        }
    }
}
