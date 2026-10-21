// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import Network

/// Reports when the phone's network changes (Wi-Fi to cellular, a new Wi-Fi, back online), in
/// place of tsnet's own link monitor, which cannot run in an iOS app.
final class NetworkPath: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "pocket.network.path")
    private var last: String?

    /// Starts watching; `changed` runs on a private queue after each change, not for the first
    /// path seen.
    func start(_ changed: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let now = Self.signature(path)
            guard now != last else { return }
            let first = last == nil
            last = now
            AppLog.shared.log("network_path", ["path": now])
            if !first { changed() }
        }
        monitor.start(queue: queue)
    }

    /// What tells one network from another here: reachable or not, and through which interfaces.
    private static func signature(_ p: NWPath) -> String {
        let status = switch p.status {
        case .satisfied: "up"
        case .unsatisfied: "down"
        case .requiresConnection: "pending"
        @unknown default: "unknown"
        }
        return ([status] + p.availableInterfaces.map(\.name)).joined(separator: " ")
    }
}
