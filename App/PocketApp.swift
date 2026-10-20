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

    /// Info.plist lists landscape for the foldable; every other iPhone stays portrait.
    func application(_ app: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Foldable.present ? .allButUpsideDown : .portrait
    }
}

/// Whether this iPhone has a hinge, learnt from the first hinge update and remembered for later
/// launches. Only a foldable gets the landscape layouts (docs/design/iphone-duo.md).
///
/// Remembering it lets a launch in landscape (the tent) start landscape. Learnt only at launch, the
/// window starts portrait and turns when the hinge reports; anything presented before that turn
/// (the call view, a sheet) holds the window portrait inside the landscape screen, drawn a quarter
/// turn off, until it is dismissed.
@MainActor
enum Foldable {
    /// Holds this device's vendor identifier: a backup restored to another iPhone carries the
    /// defaults but not the identifier, so that iPhone starts portrait-only again.
    private static let key = "foldable.vendorID"
    private(set) static var present: Bool = {
        guard let id = UIDevice.current.identifierForVendor?.uuidString else { return false }
        return UserDefaults.standard.string(forKey: key) == id
    }()

    static func found() {
        guard !present else { return }
        present = true
        if let id = UIDevice.current.identifierForVendor?.uuidString { UserDefaults.standard.set(id, forKey: key) }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
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
                // `duoduopocket://pair?...` pairs; the share extension opens the app with any
                // other URL of the scheme, with a share waiting in the inbox.
                .onOpenURL { url in model.open(url) }
                // This sheet sits outside `RootView`, so it needs the model handed in.
                .sheet(item: $model.pairSheet) { PairingSheet(request: $0).environmentObject(model) }
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
            // Also when the extension could not open the app and the user did.
            if p == .active { model.importShares() }
            if p == .active || p == .background { AmbientController.shared.audioWantChanged(name) }
            if p == .active { UIApplication.shared.isIdleTimerDisabled = AudioPreferences.keepAwake }
            if p == .background, !AmbientPolicy.continuesInBackground { AmbientController.shared.turnOff() }
            if p == .background { AnswerRefresh.schedule() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.onboarding {
                OnboardingView()
            } else {
                ConversationView()
            }
        }
        .modifier(HingeProbe())
    }
}

/// Reports a hinge once one shows up; nothing before iOS 27.1, which has no foldable.
private struct HingeProbe: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, new in if new.hinge != nil { Foldable.found() } }
        } else {
            content
        }
    }
}

/// Background App Refresh catch-up (the app has no push notifications): when iOS grants a
/// refresh, read the rows above the cursor (`GET /api/imlog?since=`) and forward the newest answer
/// the Passport has not had. iOS decides
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
