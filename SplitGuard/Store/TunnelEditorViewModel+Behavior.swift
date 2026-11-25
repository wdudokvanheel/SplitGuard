// SPDX-License-Identifier: MIT

import Foundation
import NetworkExtension
import SplitGuardCore

extension TunnelEditorViewModel {
    var onDemandPolicy: OnDemandPolicy {
        let filter: OnDemandPolicy.SSIDFilter
        if isWiFiOnDemandEnabled {
            switch ssidOption {
            case .any:
                filter = .any
            case .only:
                filter = .only(selectedSSIDs)
            case .except:
                filter = .except(selectedSSIDs)
            }
        } else {
            filter = .any
        }
        return OnDemandPolicy(
            cellular: isCellularOnDemandEnabled,
            wifi: isWiFiOnDemandEnabled,
            ssidFilter: filter
        )
    }

    var onDemandSSIDSummary: String {
        onDemandPolicy.ssidDescription
    }

    func normalizeSSIDSettings() {
        let normalized = onDemandPolicy.normalized()
        isCellularOnDemandEnabled = normalized.cellular
        isWiFiOnDemandEnabled = normalized.wifi
        ssidOption = normalized.ssidOptionKind
        selectedSSIDs = normalized.selectedSSIDs
    }

    var isOnDemandConfigured: Bool {
        isCellularOnDemandEnabled || isWiFiOnDemandEnabled
    }

    var routesAllIPv4Traffic: Bool {
        TunnelProfile.routesAllIPv4Traffic(allowedIPs: currentAllowedIPs)
    }

    var routesAllIPv6Traffic: Bool {
        TunnelProfile.routesAllIPv6Traffic(allowedIPs: currentAllowedIPs)
    }

    var tunnelOptions: TunnelOptions {
        guard isKillSwitchEnabled, routesAllIPv4Traffic else {
            return .default
        }
        return TunnelOptions(
            killSwitch: TunnelOptions.KillSwitch(
                isEnabled: true,
                allowLocalNetwork: allowLocalNetworkWithKillSwitch
            )
        )
    }

    func resolvedKillSwitchOptions(for profile: TunnelProfile) -> (TunnelOptions, AlertItem?) {
        if isKillSwitchEnabled && !profile.routesAllIPv4Traffic {
            isKillSwitchEnabled = false
            allowLocalNetworkWithKillSwitch = false
            let notice = AlertItem(
                title: "Kill Switch Turned Off",
                message: "The kill switch was turned off because this tunnel no longer routes all IPv4 traffic (0.0.0.0/0)."
            )
            return (.default, notice)
        }
        let options = TunnelOptions(
            killSwitch: TunnelOptions.KillSwitch(
                isEnabled: isKillSwitchEnabled,
                allowLocalNetwork: isKillSwitchEnabled ? allowLocalNetworkWithKillSwitch : false
            )
        )
        return (options, nil)
    }

    static func fetchConnectedSSID() async -> String? {
        #if targetEnvironment(simulator)
        return "Simulator Wi-Fi"
        #else
        return await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
        #endif
    }
}
