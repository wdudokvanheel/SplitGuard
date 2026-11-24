// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore
import WireGuardEngine

enum AllowedIPHelpers {
    static let ipv4DefaultRoute = "0.0.0.0/0"

    /// Set of all non-private (non-RFC1918) IPv4 CIDR blocks covering 0.0.0.0/0.
    static let nonPrivateIPv4Prefixes: [String] = [
        "1.0.0.0/8", "2.0.0.0/8", "3.0.0.0/8", "4.0.0.0/6", "8.0.0.0/7", "11.0.0.0/8",
        "12.0.0.0/6", "16.0.0.0/4", "32.0.0.0/3", "64.0.0.0/2", "128.0.0.0/3",
        "160.0.0.0/5", "168.0.0.0/6", "172.0.0.0/12", "172.32.0.0/11", "172.64.0.0/10",
        "172.128.0.0/9", "173.0.0.0/8", "174.0.0.0/7", "176.0.0.0/4", "192.0.0.0/9",
        "192.128.0.0/11", "192.160.0.0/13", "192.169.0.0/16", "192.170.0.0/15",
        "192.172.0.0/14", "192.176.0.0/12", "192.192.0.0/10", "193.0.0.0/8",
        "194.0.0.0/7", "196.0.0.0/6", "200.0.0.0/5", "208.0.0.0/4"
    ]

    private static let nonPrivateIPv4PrefixSet = Set(nonPrivateIPv4Prefixes)

    static func canToggleExcludePrivateIPs(peerAllowedIPs: String, peerCount: Int) -> Bool {
        guard peerCount == 1 else { return false }
        let items = normalizedItemSet(from: peerAllowedIPs)
        return items.contains(ipv4DefaultRoute) || items.isSuperset(of: nonPrivateIPv4PrefixSet)
    }

    static func isExcludingPrivateIPs(allowedIPs: String) -> Bool {
        let items = normalizedItemSet(from: allowedIPs)
        if items.contains(ipv4DefaultRoute) {
            return false
        }
        return items.isSuperset(of: nonPrivateIPv4PrefixSet)
    }

    static func applyingExcludePrivateIPs(
        _ isOn: Bool,
        to allowedIPsText: String,
        dnsText: String
    ) -> String {
        let currentItems = splitCommaSeparated(allowedIPsText)
        let ipv6Entries = normalizedPrefixStrings(currentItems.filter { $0.contains(":") })
        let dnsEntries = normalizedPrefixStrings(splitCommaSeparated(dnsText))

        let result: [String]
        if isOn {
            var combined = ipv6Entries + nonPrivateIPv4Prefixes
            for entry in dnsEntries where !combined.contains(entry) {
                combined.append(entry)
            }
            result = combined
        } else {
            let dnsSet = Set(dnsEntries)
            result = ipv6Entries.filter { !dnsSet.contains($0) } + [ipv4DefaultRoute]
        }
        return result.joined(separator: ", ")
    }

    static func updatingDNSServersInAllowedIPs(
        allowedIPsText: String,
        oldDNSText: String,
        newDNSText: String,
        isExcludingPrivateIPs: Bool
    ) -> String? {
        guard isExcludingPrivateIPs else { return nil }
        let currentItems = splitCommaSeparated(allowedIPsText)
        let oldDNSSet = Set(normalizedPrefixStrings(splitCommaSeparated(oldDNSText)))
        let newDNSEntries = normalizedPrefixStrings(splitCommaSeparated(newDNSText))

        var updated = currentItems.filter { item in
            let normalized = InterfaceAddress(item)?.network.description ?? item
            return !oldDNSSet.contains(normalized)
        }
        for entry in newDNSEntries {
            let alreadyPresent = updated.contains { item in
                (InterfaceAddress(item)?.network.description ?? item) == entry
            }
            if !alreadyPresent {
                updated.append(entry)
            }
        }
        return updated.joined(separator: ", ")
    }

    static func shouldStronglyRecommendDNS(allowedIPsText: String) -> Bool {
        let items = normalizedItemSet(from: allowedIPsText)
        return items.contains(ipv4DefaultRoute) || items.isSuperset(of: nonPrivateIPv4PrefixSet)
    }

    static func splitCommaSeparated(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedItemSet(from text: String) -> Set<String> {
        let items = splitCommaSeparated(text)
        return Set(items.map { InterfaceAddress($0)?.network.description ?? $0 })
    }

    private static func normalizedPrefixStrings(_ rawItems: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in rawItems {
            guard let normalized = InterfaceAddress(item)?.network.description else { continue }
            if seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }
        return result
    }
}
