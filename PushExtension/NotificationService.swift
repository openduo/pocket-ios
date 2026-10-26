// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import PocketPush
import UserNotifications

/// Opens a sealed answer from the channel and shows its text. Whatever cannot be opened stays the
/// placeholder the relay sent, without sound: the relay can wake the phone, not speak for 多多.
/// The text is never logged.
final class NotificationService: UNNotificationServiceExtension {
    private var pending: (content: UNMutableNotificationContent, deliver: (UNNotificationContent) -> Void)?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            return contentHandler(request.content)
        }
        // If time runs out, the placeholder goes out silent.
        content.title = String(localized: "多多")
        content.body = String(localized: "多多发来一条消息")
        content.sound = nil
        pending = (content, contentHandler)
        guard let sealed = (request.content.userInfo["s"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let key = PushStore.key(),
              let message = PushFormat.open(key: key, sealed: sealed) else {
            return finish()
        }
        let id = PushFormat.answerID(key: key, messageIDs: message.messageIDs, text: message.text)
        let (verdict, unread) = PushStore.withLedger { l in (l.admit(message, id: id), l.unread) }
        switch verdict {
        case .foreign, .replay:
            return finish()
        case .quiet:
            content.interruptionLevel = .passive
        case .alert:
            content.sound = .default
            content.badge = NSNumber(value: unread)
        }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = message.cut ? text + "…" : text
        finish()
    }

    override func serviceExtensionTimeWillExpire() { finish() }

    private func finish() {
        guard let p = pending else { return }
        pending = nil
        p.deliver(p.content)
    }
}
