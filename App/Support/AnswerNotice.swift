// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import PocketPush
import UserNotifications

/// A local notification for a message from 多多 that arrives while the app is not in front: in
/// ambient mode, or in the wake iOS gives the app for a Passport press or a background refresh.
/// With a Passport taking the answer, the Passport is the alert and the phone files the message
/// silently in Notification Centre. Opening the app clears them: the thread shows them.
///
/// With push registered, the notification carries the same identifier and thread as the push of
/// the same answer (`PushFormat`), so a push arriving after it replaces it, without a second sound.
enum AnswerNotice {
    private static let thread = "duoduo-answer"

    /// Asks for permission on activation while undecided, so a Passport-only user is asked before
    /// the first answer arrives in the background. iOS shows the prompt only while undecided.
    static func requestPermissionIfUndecided() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            guard s.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                AppLog.shared.log("notify_permission", ["granted": granted, "for": "answer"])
            }
        }
    }

    /// `silent`: the Passport already alerted, so no sound and no screen wake.
    static func post(replyID: UInt32, text: String, messageIDs: [String], silent: Bool) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "多多")
        content.body = text
        var identifier = "\(thread)-\(replyID)"
        content.threadIdentifier = thread
        if let key = PushStore.key(), let room = PushStore.withLedger({ $0.room }) {
            identifier = PushFormat.answerID(key: key, messageIDs: messageIDs, text: text)
            content.threadIdentifier = PushFormat.threadID(key: key, room: room)
            PushStore.withLedger { _ = $0.notified.insert(identifier) }
        }
        if silent {
            content.interruptionLevel = .passive
        } else {
            content.sound = .default
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            AppLog.shared.log("answer_notified", ["id": replyID, "silent": silent, "ok": error == nil])
        }
    }

    /// Removes delivered answer notifications, local and pushed; the thread now shows them. The
    /// rows up to `cursor` are read, so a late push of one of them comes without sound.
    static func withdrawAll(cursor: Int?) {
        PushStore.withLedger { $0.read(upTo: cursor) }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            // Everything the app posts but ambient notices is an answer.
            let ids = delivered.map(\.request.identifier).filter { $0 != AmbientNotice.id }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }
}
