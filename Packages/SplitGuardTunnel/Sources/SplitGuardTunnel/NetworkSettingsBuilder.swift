// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import NetworkExtension
import SplitGuardCore
import WireGuardEngine

public enum NetworkSettingsBuilder {
    public static let placeholderRemoteAddress = "127.0.0.1"
    public static let defaultMTU = 1280
    private static let maxIPv6InterfacePrefixLength = 120

    public static func build(for profile: TunnelProfile) throws -> NEPacketTunnelNetworkSettings {
        try profile.interface.validateMTU()

        /* iOS requires a tunnel endpoint, whereas in WireGuard it's valid for
         * a tunnel to have no endpoint, or for there to be many endpoints, in
         * which case displaying a single one in settings doesn't really
         * make sense. Use a placeholder that does not route over the Internet.
         */
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: placeholderRemoteAddress)

        networkSettings.dnsSettings = buildDNSSettings(for: profile)

        let mtu = profile.interface.mtu ?? 0
        networkSettings.mtu = NSNumber(value: mtu == 0 ? defaultMTU : Int(mtu))

        let (ipv4Settings, ipv6Settings) = buildIPSettings(for: profile)
        networkSettings.ipv4Settings = ipv4Settings
        networkSettings.ipv6Settings = ipv6Settings

        return networkSettings
    }

    private static func buildDNSSettings(for profile: TunnelProfile) -> NEDNSSettings? {
        let servers = profile.interface.dnsServers
        let searchDomains = profile.interface.dnsSearch
        guard !searchDomains.isEmpty || !servers.isEmpty else {
            return nil
        }

        let serverStrings = servers.map(\.description)
        switch profile.splitDNS.mode {
        case .allDomains:
            let dnsSettings = NEDNSSettings(servers: serverStrings)
            dnsSettings.searchDomains = searchDomains
            if !servers.isEmpty {
                dnsSettings.matchDomains = [""]
            }
            return dnsSettings

        case .onlyDomains:
            let matchDomains = profile.splitDNS.normalizedDomainNames
            if !servers.isEmpty && !matchDomains.isEmpty {
                let dnsSettings = NEDNSSettings(servers: serverStrings)
                dnsSettings.searchDomains = searchDomains
                dnsSettings.matchDomains = matchDomains
                dnsSettings.matchDomainsNoSearch = true
                return dnsSettings
            }
            if !searchDomains.isEmpty {
                let dnsSettings = NEDNSSettings(servers: [])
                dnsSettings.searchDomains = searchDomains
                return dnsSettings
            }
            return nil
        }
    }

    private static func buildIPSettings(for profile: TunnelProfile) -> (NEIPv4Settings, NEIPv6Settings) {
        var ipv4Addresses: [String] = []
        var ipv4SubnetMasks: [String] = []
        var ipv4IncludedRoutes: [NEIPv4Route] = []

        var ipv6Addresses: [String] = []
        var ipv6PrefixLengths: [NSNumber] = []
        var ipv6IncludedRoutes: [NEIPv6Route] = []

        for entry in profile.interface.addresses {
            if !entry.address.isIPv6 {
                let subnetMask = entry.ipv4SubnetMask?.description ?? "255.255.255.255"
                ipv4Addresses.append(entry.address.description)
                ipv4SubnetMasks.append(subnetMask)

                let route = NEIPv4Route(
                    destinationAddress: entry.network.address.description,
                    subnetMask: subnetMask
                )
                route.gatewayAddress = entry.address.description
                ipv4IncludedRoutes.append(route)
            } else {
                ipv6Addresses.append(entry.address.description)
                /* On iOS, IPv6 interface prefix lengths larger than /120 are ignored by
                 * the networking stack, so clamp the interface address prefix while keeping
                 * the un-clamped prefix length on the included route.
                 */
                let clampedPrefix = min(maxIPv6InterfacePrefixLength, Int(entry.prefixLength))
                ipv6PrefixLengths.append(NSNumber(value: clampedPrefix))

                let route = NEIPv6Route(
                    destinationAddress: entry.network.address.description,
                    networkPrefixLength: NSNumber(value: entry.prefixLength)
                )
                route.gatewayAddress = entry.address.description
                ipv6IncludedRoutes.append(route)
            }
        }

        for peer in profile.peers {
            for prefix in peer.allowedIPs {
                if !prefix.address.isIPv6 {
                    let subnetMask = prefix.ipv4SubnetMask?.description ?? "255.255.255.255"
                    ipv4IncludedRoutes.append(
                        NEIPv4Route(
                            destinationAddress: prefix.address.description,
                            subnetMask: subnetMask
                        )
                    )
                } else {
                    ipv6IncludedRoutes.append(
                        NEIPv6Route(
                            destinationAddress: prefix.address.description,
                            networkPrefixLength: NSNumber(value: prefix.length)
                        )
                    )
                }
            }
        }

        let ipv4Settings = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4SubnetMasks)
        ipv4Settings.includedRoutes = ipv4IncludedRoutes

        let ipv6Settings = NEIPv6Settings(addresses: ipv6Addresses, networkPrefixLengths: ipv6PrefixLengths)
        ipv6Settings.includedRoutes = ipv6IncludedRoutes

        return (ipv4Settings, ipv6Settings)
    }
}
