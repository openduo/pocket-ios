// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import PocketPush
import Security

/// What the app and its notification service extension share for push: the sealing key (Keychain,
/// app-group access group) and the ledger (app-group defaults). Both targets carry
/// `PocketAppGroup` in their Info.plist.
enum PushStore {
    static var group: String? { Bundle.main.object(forInfoDictionaryKey: "PocketAppGroup") as? String }

    // MARK: key

    private static let service = "dev.openduo.pocket.push"
    private static let account = "key"

    private static func query() -> [String: Any]? {
        guard let group else { return nil }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecAttrAccessGroup as String: group]
    }

    /// The key, or nil before the app made one (or before the first unlock after a reboot).
    static func key() -> Data? {
        guard var q = query() else { return nil }
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              d.count == PushFormat.keyBytes else { return nil }
        return d
    }

    /// Stores a new key, replacing any old one. Readable after the first unlock (a push can arrive
    /// on a locked phone), never synced or backed up to another device.
    @discardableResult
    static func makeKey() -> Data? {
        guard let q = query() else { return nil }
        SecItemDelete(q as CFDictionary)
        let key = PushFormat.newKey()
        var add = q
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? key : nil
    }

    static func dropKey() {
        if let q = query() { SecItemDelete(q as CFDictionary) }
    }

    // MARK: ledger

    private static let ledgerKey = "push.ledger"

    /// Read, change and write the ledger. The app and the extension run in separate processes; a
    /// lost update only costs one extra or one missing sound.
    static func withLedger<T>(_ f: (inout PushLedger) -> T) -> T {
        let defaults = group.flatMap { UserDefaults(suiteName: $0) }
        var ledger = defaults?.data(forKey: ledgerKey).flatMap { try? JSONDecoder().decode(PushLedger.self, from: $0) }
            ?? PushLedger()
        let out = f(&ledger)
        if let data = try? JSONEncoder().encode(ledger) { defaults?.set(data, forKey: ledgerKey) }
        return out
    }
}
