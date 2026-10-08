// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import BackgroundTasks
import PocketCore
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppPhase.set(app.applicationState == .background ? "background" : "launching")
        let centrals = opts?[.bluetoothCentrals] as? [String] ?? []
        AppLog.shared.log("launch", ["app": AppPhase.value, "restored_centrals": centrals,
                                     "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""])
        // The central must exist before this returns for BLE state restoration to deliver.
        PocketEngine.shared.start()
        _ = ConversationStore.shared
        // Registration must finish before launch ends (BGTaskScheduler requirement).
        AnswerRefresh.register()
        #if DEBUG
        Demo.runAmbientProbe()
        Demo.runPlaybackProbe()
        #endif
        return true
    }
}

@main
struct PocketApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var phase
    @StateObject private var model = AppModel()

    init() {
        // PocketCore builds some UI text itself; it follows the app's resolved language.
        PocketStrings.language = PocketEngine.uiLanguage
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(model.colorScheme)
                .tint(Palette.brand)
        }
        .onChange(of: phase) { _, p in
            let name: String = switch p {
            case .active: "active"
            case .inactive: "inactive"
            case .background: "background"
            @unknown default: "unknown"
            }
            AppPhase.set(name)
            AppLog.shared.log("scene_phase", ["phase": name])
            model.setActive(p == .active)
            if p == .active { PocketEngine.shared.appBecameActive() }
            if p == .background, !AmbientPolicy.continuesInBackground { AmbientController.shared.turnOff() }
            if p == .background { AnswerRefresh.schedule() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.onboarding {
            OnboardingView()
        } else {
            ConversationView()
        }
    }
}

/// Background App Refresh catch-up (the app has no push notifications): when iOS grants a
/// refresh, read the room log and forward the newest answer the Passport has not had. iOS decides
/// when (and whether) it runs; the request asks for no earliest time, so there is no interval
/// constant.
enum AnswerRefresh {
    /// Also listed under `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let id = "dev.openduo.pocket.refresh"

    static func register() {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return task.setTaskCompleted(success: false) }
            run(task)
        }
        if !ok { AppLog.shared.log("bg_refresh_register_failed") }
    }

    static func schedule() {
        do {
            try BGTaskScheduler.shared.submit(BGAppRefreshTaskRequest(identifier: id))
        } catch {
            AppLog.shared.log("bg_refresh_schedule_error", ["err": "\(error)"])
        }
    }

    private static func run(_ task: BGAppRefreshTask) {
        AppLog.shared.log("bg_refresh", ["app": AppPhase.value])
        // Each run asks for the next one; iOS keeps one pending request per identifier.
        schedule()
        let once = Once()
        task.expirationHandler = {
            guard once.claim() else { return }
            AppLog.shared.log("bg_refresh_expired")
            task.setTaskCompleted(success: false)
        }
        PocketEngine.shared.fetchMissed("bg_refresh") { ok in
            guard once.claim() else { return }
            task.setTaskCompleted(success: ok)
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
