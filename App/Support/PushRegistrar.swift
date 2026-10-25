// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import PocketCore
import PocketPush
import UIKit

/// Push for answers that arrive while the app is suspended (docs/push.md). The phone asks the push
/// relay for a grant for its APNs address, makes its own sealing key, and registers both with its
/// channel; the channel then sends 多多's answers sealed through the relay, and `DuoduoPush` opens
/// them. Nothing is asked of a channel that does not advertise push (`/api/state` `push`).
///
/// A grant expires (the relay keeps no state, so only age can void one); it is renewed at every
/// launch, every Background App Refresh and every pairing.
final class PushRegistrar: @unchecked Sendable {
    static let shared = PushRegistrar()

    private let queue = DispatchQueue(label: "pocket.push")
    private var apnsToken: String?
    private var running = false
    private var again = false
    /// True once a registration succeeded in this process; until then each `/live` ready retries.
    private var registered = false

    /// At launch: ask APNs for this phone's address. It needs no permission; showing an alert does,
    /// and `AnswerNotice` asks for that.
    @MainActor func start() { UIApplication.shared.registerForRemoteNotifications() }

    func tokenReceived(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        queue.async { [self] in
            apnsToken = hex
            refreshOnQueue("token")
        }
    }

    /// A new pairing: a new channel gets a new key, and the old ledger means nothing to it.
    func paired() {
        PushStore.dropKey()
        PushStore.withLedger { $0 = PushLedger(room: ChannelSettings.load().room) }
        refresh("paired")
    }

    /// Registers unless this process already did: at `/live` ready, after a launch whose first try
    /// came before the tailnet was up.
    func registerIfPending(_ why: String) {
        // A run in progress settles it either way; the next ready retries a failure.
        queue.async { [self] in if !registered, !running { refreshOnQueue(why) } }
    }

    /// Renews the grant and the registration; `done` reports whether it registered.
    func refresh(_ why: String, done: (@Sendable (Bool) -> Void)? = nil) {
        queue.async { [self] in refreshOnQueue(why, done: done) }
    }

    private func refreshOnQueue(_ why: String, done: (@Sendable (Bool) -> Void)? = nil) {
        guard let token = apnsToken else { done?(false); return }
        if running { again = true; done?(false); return }
        running = true
        Task.detached { [self] in
            let ok = await register(token: token, why: why)
            done?(ok)
            queue.async { [self] in
                running = false
                if ok { registered = true }
                if again { again = false; refreshOnQueue("again") }
            }
        }
    }

    private func register(token: String, why: String) async -> Bool {
        let settings = ChannelSettings.load()
        guard !TryMode.active, settings.isComplete, DeviceCredentials.shared.token != nil,
              !DeviceCredentials.shared.unauthorized else { return false }
        let client = ChannelClient(settings: settings, tuning: PocketTuning.load())
        do {
            let state = try await client.state()
            guard state.push else {
                AppLog.shared.log("push_unavailable", ["why": why])
                return false
            }
            guard let key = PushStore.key() ?? PushStore.makeKey() else {
                AppLog.shared.log("push_key_unavailable", ["why": why])
                return false
            }
            let grant = try await Self.grant(token: token)
            try await client.registerPush(grant: grant, key: key)
            PushStore.withLedger { $0.room = settings.room }
            AppLog.shared.log("push_registered", ["why": why, "env": Self.environment])
            return true
        } catch {
            AppLog.shared.log("push_register_failed", ["why": why, "err": "\(error)"])
            return false
        }
    }

    private enum RelayError: Error { case status(Int) }

    /// `POST /v1/grant` on the relay, over the internet (not the tailnet).
    private static func grant(token: String) async throws -> String {
        var req = URLRequest(url: PushFormat.relay.appendingPathComponent("v1/grant"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["token": token, "environment": environment])
        let (data, res) = try await URLSession.shared.data(for: req)
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let grant = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["grant"] as? String
        else { throw RelayError.status(status) }
        return grant
    }

    /// APNs environment of this build: development-signed builds carry a provisioning profile
    /// saying `development`; App Store and TestFlight builds carry none and use production.
    static let environment: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let text = String(data: raw, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>"),
              let xml = String(text[start.lowerBound..<end.upperBound]).data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return "production" }
        return entitlements["aps-environment"] as? String == "development" ? "sandbox" : "production"
    }()
}
