// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import UserNotifications

/// The app's only local notification: ambient mode was interrupted and iOS did not let it resume.
/// Tapping it opens the app, which resumes ambient mode on activation. Alert only: no sound, no
/// badge.
enum AmbientNotice {
    private static let id = "ambient-interrupted"

    /// Asks for alert permission the first time ambient mode is turned on. iOS shows the prompt
    /// only while undecided; a denial changes nothing else.
    static func requestPermissionIfUndecided() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            guard s.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert]) { granted, _ in
                AppLog.shared.log("notify_permission", ["granted": granted])
            }
        }
    }

    static func post() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "环境模式被打断了")
        content.body = String(localized: "点这里回到多多，继续听房间里的声音。")
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            AppLog.shared.log("ambient_interrupt_notified", ["ok": error == nil])
        }
    }

    /// Removes the notice, delivered or pending.
    static func withdraw() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
}
