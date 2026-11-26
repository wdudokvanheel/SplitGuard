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
            return L10n.tr("error.tunnelNameEmpty.title", defaultValue: "No name provided")
        case .tunnelNameAlreadyExists:
            return L10n.tr("error.tunnelNameExists.title", defaultValue: "Name already exists")
        case .loadFailed:
            return L10n.tr("error.loadFailed.title", defaultValue: "Unable to load tunnels")
        case .saveFailed:
            return L10n.tr("error.saveFailed.title", defaultValue: "Unable to save tunnel")
        case .removeFailed:
            return L10n.tr("error.removeFailed.title", defaultValue: "Unable to remove tunnel")
        case .startFailed(let startError):
            return startError.localizedTitle
        case .activationAttemptFailed:
            return L10n.tr("error.activationFailed.title", defaultValue: "Activation failure")
        case .tunnelNotFound:
            return L10n.tr("error.tunnelNotFound.title", defaultValue: "Tunnel not found")
        case .noTunnelsToExport:
            return L10n.tr("error.noTunnelsToExport.title", defaultValue: "Nothing to export")
        case .exportFailed:
            return L10n.tr("error.exportFailed.title", defaultValue: "Export failed")
        case .importFailed:
            return L10n.tr("error.importFailed.title", defaultValue: "Import failed")
        }
    }

    var message: String {
        switch self {
        case .tunnelNameEmpty:
            return L10n.tr("error.tunnelNameEmpty.message", defaultValue: "A tunnel name cannot be empty.")
        case .tunnelNameAlreadyExists(let name):
            return L10n.tr(
                "error.tunnelNameExists.message",
                defaultValue: "Another tunnel with the name \"\(name)\" already exists."
            )
        case .loadFailed(let detail):
            return detail
        case .saveFailed(let detail):
            return detail
        case .removeFailed(let detail):
            return detail
        case .startFailed(let startError):
            return startError.localizedMessage
        case .activationAttemptFailed(let detail):
            return detail
        case .tunnelNotFound:
            return L10n.tr("error.tunnelNotFound.message", defaultValue: "The selected tunnel no longer exists.")
        case .noTunnelsToExport:
            return L10n.tr(
                "error.noTunnelsToExport.message",
                defaultValue: "There are no tunnels available to export."
            )
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
                return L10n.tr("error.vpn.configurationInvalid", defaultValue: "The tunnel configuration is invalid.")
            case .configurationDisabled:
                return L10n.tr("error.vpn.configurationDisabled", defaultValue: "The tunnel configuration is disabled.")
            case .connectionFailed:
                return L10n.tr("error.vpn.connectionFailed", defaultValue: "The VPN connection failed.")
            case .configurationStale:
                return L10n.tr("error.vpn.configurationStale", defaultValue: "The tunnel configuration is out of date.")
            case .configurationReadWriteFailed:
                return L10n.tr(
                    "error.vpn.configurationReadWriteFailed",
                    defaultValue: "Failed to read or write the tunnel configuration."
                )
            case .configurationUnknown:
                return L10n.tr(
                    "error.vpn.configurationUnknown",
                    defaultValue: "An unknown VPN configuration error occurred."
                )
            @unknown default:
                return vpnError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

extension TunnelStartError {
    var localizedTitle: String {
        switch self {
        case .invalidConfiguration:
            return L10n.tr("error.start.invalidConfig.title", defaultValue: "Invalid tunnel configuration")
        case .dnsResolutionFailed:
            return L10n.tr("error.start.dnsFailed.title", defaultValue: "Endpoint DNS resolution failed")
        case .networkSettingsFailed:
            return L10n.tr("error.start.networkSettings.title", defaultValue: "Failed to apply network settings")
        case .engineStartFailed:
            return L10n.tr("error.start.engineFailed.title", defaultValue: "Failed to start tunnel engine")
        }
    }

    var localizedMessage: String {
        switch self {
        case .invalidConfiguration:
            return L10n.tr(
                "error.start.invalidConfig.message",
                defaultValue: "The saved tunnel configuration could not be loaded."
            )
        case .dnsResolutionFailed(let hostnames):
            let cleaned = hostnames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if cleaned.isEmpty {
                return L10n.tr(
                    "error.start.dnsFailed.generic",
                    defaultValue: "Could not resolve one or more peer endpoint hostnames."
                )
            }
            let list = cleaned.joined(separator: ", ")
            return L10n.tr(
                "error.start.dnsFailed.hostnames",
                defaultValue: "Could not resolve endpoint hostname(s): \(list)."
            )
        case .networkSettingsFailed(let detail):
            if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return L10n.tr(
                    "error.start.networkSettings.detail",
                    defaultValue: "Could not configure tunnel network settings: \(detail)"
                )
            }
            return L10n.tr(
                "error.start.networkSettings.generic",
                defaultValue: "Could not configure tunnel network settings."
            )
        case .engineStartFailed(let detail):
            if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return L10n.tr(
                    "error.start.engineFailed.detail",
                    defaultValue: "Could not start the WireGuard engine: \(detail)"
                )
            }
            return L10n.tr(
                "error.start.engineFailed.generic",
                defaultValue: "Could not start the WireGuard engine."
            )
        }
    }
}

extension SplitDNSConfiguration.ValidationWarning {
    var localizedMessage: String {
        switch self {
        case .noDNSServer:
            return L10n.tr(
                "splitDNS.warning.noDNSServer",
                defaultValue: "Split DNS is enabled, but this tunnel has no DNS server. Add one under DNS servers."
            )
        case .dnsServerOutsideAllowedIPs(let servers):
            let joined = servers.joined(separator: ", ")
            if servers.count == 1 {
                return L10n.tr(
                    "splitDNS.warning.dnsOutsideSingle",
                    defaultValue: "DNS server \(joined) is outside the tunnel's Allowed IPs, so queries may not reach it."
                )
            }
            return L10n.tr(
                "splitDNS.warning.dnsOutsideMultiple",
                defaultValue: "DNS servers \(joined) are outside the tunnel's Allowed IPs, so queries may not reach them."
            )
        case .exclusionOutsideMatchDomains(let name):
            return L10n.tr(
                "splitDNS.warning.exclusionOutside",
                defaultValue: "\"\(name)\" is not under any tunnel DNS domain, so excluding it has no effect in this mode."
            )
        case .exclusionCancelsDomain(let name):
            return L10n.tr(
                "splitDNS.warning.exclusionCancels",
                defaultValue: """
                Excluding "\(name)" with subdomains cancels the tunnel DNS domain "\(name)". \
                Use "this name only" to exclude only the apex.
                """
            )
        }
    }
}

extension SplitDNSConfiguration.DomainValidationError {
    var localizedMessage: String {
        switch self {
        case .empty:
            return L10n.tr("splitDNS.error.empty", defaultValue: "Enter a domain name such as hw45.nl.")
        case .invalidSyntax(let value):
            return L10n.tr(
                "splitDNS.error.invalidSyntax",
                defaultValue: "\"\(value)\" is not a valid domain name. Use letters, numbers, hyphens, and dots without wildcards or ports."
            )
        case .duplicate(let value):
            return L10n.tr("splitDNS.error.duplicate", defaultValue: "\"\(value)\" is already in the list.")
        }
    }
}
