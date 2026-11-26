// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore
import SplitGuardTunnel
import UserNotifications

final class UserNotificationHealthAlertPoster: HealthAlertNotificationPosting, @unchecked Sendable {
    static let tunnelIDUserInfoKey = "tunnelID"

    private static let languageDefaultsKey = "splitguard.language"
    private static let supportedLanguages: Set<String> = ["en", "es", "fr", "de", "nl"]

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func post(_ notification: HealthAlertNotification) {
        let localized = Self.localizedText(for: notification)
        let content = UNMutableNotificationContent()
        content.title = localized.title
        content.body = localized.body
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

    private static func localizedText(for notification: HealthAlertNotification) -> (title: String, body: String) {
        let langCode = resolveLanguageCode()
        let locale = Locale(identifier: langCode)
        let bundle = localizedBundle(for: langCode)

        switch notification.kind {
        case .recovered:
            return localizedRecoveredText(for: notification, bundle: bundle, locale: locale)
        case .noHandshake, .stalled:
            return localizedUnhealthyText(for: notification, bundle: bundle, locale: locale)
        }
    }

    private static func localizedRecoveredText(
        for notification: HealthAlertNotification,
        bundle: Bundle,
        locale: Locale
    ) -> (title: String, body: String) {
        let name = notification.tunnelName
        let title = tr(
            "healthAlerts.notification.recovered.title",
            defaultValue: "\(name): Connection recovered",
            bundle: bundle,
            locale: locale
        )
        let body = notification.killSwitchEnabled
            ? tr(
                "healthAlerts.notification.recovered.bodyBlocked",
                defaultValue: "Handshake succeeded. Tunnel traffic has resumed.",
                bundle: bundle,
                locale: locale
            )
            : tr(
                "healthAlerts.notification.recovered.bodyNormal",
                defaultValue: "Handshake succeeded and the tunnel is healthy again.",
                bundle: bundle,
                locale: locale
            )
        return (title, body)
    }

    private static func localizedUnhealthyText(
        for notification: HealthAlertNotification,
        bundle: Bundle,
        locale: Locale
    ) -> (title: String, body: String) {
        let name = notification.tunnelName
        let duration = formatDelay(notification.delaySeconds ?? 60, bundle: bundle, locale: locale)
        if notification.killSwitchEnabled {
            return (
                tr("healthAlerts.notification.blocked.title", defaultValue: "\(name): Traffic blocked", bundle: bundle, locale: locale),
                tr(
                    "healthAlerts.notification.blocked.body",
                    defaultValue: "No working handshake for \(duration). Traffic is blocked until the server responds.",
                    bundle: bundle,
                    locale: locale
                )
            )
        }
        if notification.kind == .stalled {
            return (
                tr("healthAlerts.notification.stalled.title", defaultValue: "\(name): Connection stalled", bundle: bundle, locale: locale),
                tr(
                    "healthAlerts.notification.stalled.body",
                    defaultValue: "Sent traffic has received no answer for \(duration).",
                    bundle: bundle,
                    locale: locale
                )
            )
        }
        return (
            tr("healthAlerts.notification.noHandshake.title", defaultValue: "\(name): No handshake", bundle: bundle, locale: locale),
            tr(
                "healthAlerts.notification.noHandshake.body",
                defaultValue: "No working handshake for \(duration). Check the peer key, endpoint, or network.",
                bundle: bundle,
                locale: locale
            )
        )
    }

    private static func formatDelay(_ seconds: Int, bundle: Bundle, locale: Locale) -> String {
        let clamped = max(1, seconds)
        if clamped < 60 {
            return tr("healthAlerts.delay.seconds", defaultValue: "\(clamped) seconds", bundle: bundle, locale: locale)
        }
        let minutes = clamped / 60
        let remainder = clamped % 60
        if remainder == 0 {
            return tr("healthAlerts.delay.minutes", defaultValue: "\(minutes) minutes", bundle: bundle, locale: locale)
        }
        return tr(
            "healthAlerts.delay.minutesSeconds",
            defaultValue: "\(minutes)m \(remainder)s",
            bundle: bundle,
            locale: locale
        )
    }

    private static func resolveLanguageCode() -> String {
        if let groupID = AppGroup.identifier(),
           let shared = UserDefaults(suiteName: groupID),
           let stored = shared.string(forKey: languageDefaultsKey),
           supportedLanguages.contains(stored) {
            return stored
        }
        for identifier in Locale.preferredLanguages {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-")
            if let primary = normalized.split(separator: "-").first?.lowercased(),
               supportedLanguages.contains(primary) {
                return primary
            }
        }
        return "en"
    }

    private static func localizedBundle(for languageCode: String) -> Bundle {
        if let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        if let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }

    private static func tr(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        bundle: Bundle,
        locale: Locale
    ) -> String {
        String(localized: key, defaultValue: defaultValue, table: nil, bundle: bundle, locale: locale, comment: "")
    }
}
