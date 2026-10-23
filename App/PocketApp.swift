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
        // Before launch returns: a relaunch for a visit delivers it to this delegate.
        ArrivalMonitor.shared.start(relaunchedForLocation: opts?[.location] != nil)
        // Registration must finish before launch ends (BGTaskScheduler requirement).
        AnswerRefresh.register()
        MetricsLog.shared.start()
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

/// Whether this iPhone folds. Only a foldable gets the landscape layouts (docs/design/iphone-duo.md).
///
/// Known from the first frame by the screen's shape, so a launch in landscape (the tent) starts
/// landscape: a window that starts portrait and turns later stays portrait, drawn a quarter turn
/// off, under anything presented before the turn (the call view, a sheet). A hinge update confirms
/// it for a foldable whose screens this check does not recognise.
@MainActor
enum Foldable {
    private static var hingeSeen = false
    /// Both displays of a foldable are far squarer than any iPhone that does not fold: the squarest
    /// of those is the 16:9 iPhone SE (1334 x 750 px), and the foldable's are about 1.45:1.
    private static let screenFolds: Bool = {
        let size = UIScreen.main.nativeBounds.size
        return max(size.width, size.height) / min(size.width, size.height) < 16.0 / 9.0
    }()

    static var present: Bool { screenFolds || hingeSeen }

    static func found() {
        guard !present else { return }
        hingeSeen = true
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
            // The network may have changed while the app was suspended.
            if p == .active { Tailnet.shared.rebind() }
            if p == .active { PocketEngine.shared.appBecameActive() }
            if p == .active { AmbientController.shared.appBecameActive() }
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
