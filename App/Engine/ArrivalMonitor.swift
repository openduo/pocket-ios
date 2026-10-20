// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import CoreLocation
import Observation
import PocketCore
import UIKit

/// Settings › 让多多知道我到了哪: iOS visit monitoring names each place the user arrives at, and the
/// next message (or ambient mode's next `/live` connection) carries it to the user's own 多多 as
/// `X-Ambient-Place`. Off by default; works only with Always location permission.
///
/// Visits are arrivals only: no continuous location, no background location mode. iOS relaunches
/// a terminated app in the background for a visit; `start()` runs in `didFinishLaunching`, so the
/// delegate is set and monitoring restarted before the visit is delivered.
///
/// The manager lives on the main thread; `report()` and `settle` are safe from any thread.
@Observable
final class ArrivalMonitor: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    static let shared = ArrivalMonitor()

    /// UserDefaults key of the setting (default off).
    static let enabledKey = "place.arrivals"

    /// The setting, mirrored for the Settings screen.
    private(set) var enabled = UserDefaults.standard.bool(forKey: ArrivalMonitor.enabledKey)
    /// Location permission, for the Settings screen.
    private(set) var status: CLAuthorizationStatus = .notDetermined

    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private let ledger = PlaceLedger()
    /// Setting on and Always granted; read off the main thread by the request paths.
    @ObservationIgnored private let active = Locked(false)
    private var isActive: Bool { active.withLock { $0 } }

    /// Whether the setting is on but has no effect for lack of Always permission.
    var needsAlways: Bool { enabled && status != .authorizedAlways }

    /// Creates the manager and restarts monitoring when the setting is on. Main thread, at launch.
    func start(relaunchedForLocation: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        if relaunchedForLocation { AppLog.shared.log("arrival_relaunch") }
        guard manager == nil else { return }
        let m = CLLocationManager()
        m.delegate = self
        manager = m
        refresh()
    }

    /// The switch in Settings. On asks for When In Use, then Always; off stops monitoring and
    /// forgets the stored places.
    func setEnabled(_ on: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        AppLog.shared.log("arrival_setting", ["on": on])
        if !on { ledger.clear() }
        refresh()
        guard on, let m = manager else { return }
        switch m.authorizationStatus {
        case .notDetermined: m.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: m.requestAlwaysAuthorization()
        default: break
        }
    }

    /// The pending arrival to attach to a request, or nil (setting off, no Always, nothing new,
    /// or 先体验, whose channel is in the app).
    func report() -> PlaceReport? {
        guard isActive, !TryMode.active else { return nil }
        return ledger.pending()
    }

    /// The outcome of a request that carried `report`: accepted (202, or the `/live` upgrade)
    /// marks that place reported.
    func settle(_ report: PlaceReport?, accepted: Bool) {
        ledger.settle(report, accepted: accepted)
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let before = status
        refresh()
        AppLog.shared.log("arrival_auth", ["status": Int(m.authorizationStatus.rawValue)])
        // The second step: When In Use was just granted while the setting asks for arrivals.
        if enabled, before == .notDetermined, m.authorizationStatus == .authorizedWhenInUse {
            m.requestAlwaysAuthorization()
        }
    }

    func locationManager(_ m: CLLocationManager, didVisit visit: CLVisit) {
        // A distant-past arrival is the departure half of a visit seen without its arrival.
        guard isActive, visit.arrivalDate != .distantPast else { return }
        let arrived = visit.arrivalDate
        let location = CLLocation(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude)
        // A background relaunch gets a few seconds; the lookup is one network request.
        let task = UIApplication.shared.beginBackgroundTask(withName: "arrival")
        Task { @MainActor [self] in
            defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
            let n = await ReverseGeocoder.name(location)
            guard isActive, let name = (n?.name).flatMap({ $0.isEmpty ? nil : $0 }) else {
                AppLog.shared.log("arrival", ["named": false])
                return
            }
            let changed = ledger.arrived(ArrivalPlace(name: name, area: n?.area ?? "", arrived: arrived))
            AppLog.shared.log("arrival", ["named": true, "changed": changed])
        }
    }

    // MARK: -

    private func refresh() {
        guard let m = manager else { return }
        status = m.authorizationStatus
        let on = enabled && status == .authorizedAlways
        active.withLock { $0 = on }
        if on { m.startMonitoringVisits() } else { m.stopMonitoringVisits() }
    }
}
