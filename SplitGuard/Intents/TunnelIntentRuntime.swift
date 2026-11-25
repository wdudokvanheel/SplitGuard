// SPDX-License-Identifier: MIT

import AppIntents
import Foundation
import SplitGuardCore

enum TunnelIntentError: Error, Equatable, LocalizedError, CustomLocalizedStringResourceConvertible, Sendable {
    case tunnelNotFound(String?)
    case startFailed(title: String, message: String)
    case timedOut(tunnelName: String, action: String)
    case missingTunnel(action: String)
    case operationFailed(title: String, message: String)

    var title: String {
        switch self {
        case .tunnelNotFound:
            return TunnelError.tunnelNotFound.title
        case .startFailed(let title, _):
            return title
        case .timedOut(_, let action):
            return "Tunnel \(action) timed out"
        case .missingTunnel:
            return "No tunnel selected"
        case .operationFailed(let title, _):
            return title
        }
    }

    var message: String {
        switch self {
        case .tunnelNotFound(let name):
            if let name, !name.isEmpty {
                return "The tunnel “\(name)” no longer exists."
            }
            return TunnelError.tunnelNotFound.message
        case .startFailed(_, let message):
            return message
        case .timedOut(let tunnelName, let action):
            return "Timed out waiting for “\(tunnelName)” to \(action)."
        case .missingTunnel(let action):
            return "Choose a tunnel to \(action)."
        case .operationFailed(_, let message):
            return message
        }
    }

    var localizedStringResource: LocalizedStringResource {
        "\(title): \(message)"
    }

    var errorDescription: String? {
        "\(title): \(message)"
    }

    static func map(_ error: Error, tunnelName: String?, action: String) -> TunnelIntentError {
        if let intentError = error as? TunnelIntentError {
            return intentError
        }
        if let waitError = error as? TunnelActivationService.WaitError {
            switch waitError {
            case .timedOut:
                return .timedOut(tunnelName: tunnelName ?? "tunnel", action: action)
            case .tunnelError(let tunnelError):
                return mapTunnelError(tunnelError, tunnelName: tunnelName)
            }
        }
        if let tunnelError = error as? TunnelError {
            return mapTunnelError(tunnelError, tunnelName: tunnelName)
        }
        return .operationFailed(title: "Tunnel error", message: TunnelError.describeSystemError(error))
    }

    private static func mapTunnelError(_ error: TunnelError, tunnelName: String?) -> TunnelIntentError {
        switch error {
        case .tunnelNotFound:
            return .tunnelNotFound(tunnelName)
        case .startFailed(let startError):
            return .startFailed(title: startError.title, message: startError.message)
        default:
            return .operationFailed(title: error.title, message: error.message)
        }
    }
}

@MainActor
enum TunnelIntentRuntime {
    private static var serviceOverride: TunnelActivationService?

    static var service: TunnelActivationService {
        if let serviceOverride {
            return serviceOverride
        }
        Log.configure(source: "APP", fileURL: AppGroup.appLogURL())
        return TunnelActivationService.shared
    }

    static func withService<T>(
        _ override: TunnelActivationService,
        operation: @MainActor () async throws -> T
    ) async rethrows -> T {
        let previous = serviceOverride
        serviceOverride = override
        defer { serviceOverride = previous }
        return try await operation()
    }
}
