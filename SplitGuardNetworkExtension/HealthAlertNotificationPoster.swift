// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore
import SplitGuardTunnel
import UserNotifications

final class UserNotificationHealthAlertPoster: HealthAlertNotificationPosting, @unchecked Sendable {
    static let tunnelIDUserInfoKey = "tunnelID"

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func post(_ notification: HealthAlertNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = notification.threadIdentifier
        content.userInfo = [
            Self.tunnelIDUserInfoKey: notification.tunnelID.uuidString,
            "kind": notification.kind.rawValue
        ]

        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                Log.error("Health alert notification failed (\(notification.identifier)): \(error.localizedDescription)")
            } else {
                Log.info("Health alert notification scheduled (\(notification.identifier))")
            }
        }
    }

    func removeDelivered(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
