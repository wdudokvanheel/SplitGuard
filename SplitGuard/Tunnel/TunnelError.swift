// SPDX-License-Identifier: MIT

import Foundation
import NetworkExtension
import SplitGuardCore

enum TunnelError: Error, Equatable, LocalizedError, Sendable {
    case tunnelNameEmpty
    case tunnelNameAlreadyExists(String)
    case loadFailed(String)
    case saveFailed(String)
    case removeFailed(String)
    case startFailed(TunnelStartError)
    case activationAttemptFailed(String)
    case tunnelNotFound
    case noTunnelsToExport
    case exportFailed(String)
    case importFailed(String)

    var title: String {
        switch self {
        case .tunnelNameEmpty:
            return "No name provided"
        case .tunnelNameAlreadyExists:
            return "Name already exists"
        case .loadFailed:
            return "Unable to load tunnels"
        case .saveFailed:
            return "Unable to save tunnel"
        case .removeFailed:
            return "Unable to remove tunnel"
        case .startFailed(let startError):
            return startError.title
        case .activationAttemptFailed:
            return "Activation failure"
        case .tunnelNotFound:
            return "Tunnel not found"
        case .noTunnelsToExport:
            return "Nothing to export"
        case .exportFailed:
            return "Export failed"
        case .importFailed:
            return "Import failed"
        }
    }

    var message: String {
        switch self {
        case .tunnelNameEmpty:
            return "A tunnel name cannot be empty."
        case .tunnelNameAlreadyExists(let name):
            return "Another tunnel with the name \"\(name)\" already exists."
        case .loadFailed(let detail):
            return detail
        case .saveFailed(let detail):
            return detail
        case .removeFailed(let detail):
            return detail
        case .startFailed(let startError):
            return startError.message
        case .activationAttemptFailed(let detail):
            return detail
        case .tunnelNotFound:
            return "The selected tunnel no longer exists."
        case .noTunnelsToExport:
            return "There are no tunnels available to export."
        case .exportFailed(let detail):
            return detail
        case .importFailed(let detail):
            return detail
        }
    }

    var errorDescription: String? {
        message
    }

    var alertItem: AlertItem {
        AlertItem(title: title, message: message)
    }

    static func describeSystemError(_ error: Error) -> String {
        if let tunnelError = error as? TunnelError {
            return tunnelError.message
        }
        if let vpnError = error as? NEVPNError {
            switch vpnError.code {
            case .configurationInvalid:
                return "The tunnel configuration is invalid."
            case .configurationDisabled:
                return "The tunnel configuration is disabled."
            case .connectionFailed:
                return "The VPN connection failed."
            case .configurationStale:
                return "The tunnel configuration is out of date."
            case .configurationReadWriteFailed:
                return "Failed to read or write the tunnel configuration."
            case .configurationUnknown:
                return "An unknown VPN configuration error occurred."
            @unknown default:
                return vpnError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
