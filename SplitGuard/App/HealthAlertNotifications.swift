// SPDX-License-Identifier: MIT

import Foundation
import UserNotifications

enum HealthAlertAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case unavailable
}

protocol HealthAlertPermissionManaging: Sendable {
    func authorizationState() async -> HealthAlertAuthorizationState
    func requestAuthorization() async -> HealthAlertAuthorizationState
}

struct SystemHealthAlertPermissionManager: HealthAlertPermissionManaging {
    func authorizationState() async -> HealthAlertAuthorizationState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    func requestAuthorization() async -> HealthAlertAuthorizationState {
        let current = await authorizationState()
        switch current {
        case .authorized, .denied, .unavailable:
            return current
        case .notDetermined:
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound]
                )
                return granted ? .authorized : .denied
            } catch {
                return .denied
            }
        }
    }

    private static func map(_ status: UNAuthorizationStatus) -> HealthAlertAuthorizationState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        @unknown default:
            return .unavailable
        }
    }
}

@MainActor
final class NotificationNavigationCoordinator {
    static let shared = NotificationNavigationCoordinator()
    static let tunnelIDUserInfoKey = "tunnelID"

    private var pendingTunnelID: UUID?
    private var handler: ((UUID) -> Void)?

    private init() {}

    func register(handler: @escaping (UUID) -> Void) {
        self.handler = handler
        if let pending = pendingTunnelID {
            pendingTunnelID = nil
            handler(pending)
        }
    }

    @discardableResult
    func handle(userInfo: [AnyHashable: Any]) -> Bool {
        guard let rawID = userInfo[Self.tunnelIDUserInfoKey] as? String,
              let tunnelID = UUID(uuidString: rawID) else {
            return false
        }
        if let handler {
            handler(tunnelID)
        } else {
            pendingTunnelID = tunnelID
        }
        return true
    }
}
