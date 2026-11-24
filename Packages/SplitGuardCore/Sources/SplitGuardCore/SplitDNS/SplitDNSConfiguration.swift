// SPDX-License-Identifier: MIT
// SplitGuard: native Split DNS model, exclusions, validation, and routing preview.

import Foundation
import WireGuardEngine

public struct SplitDNSConfiguration: Codable, Equatable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
        case allDomains
        case onlyDomains
    }

    public struct Domain: Codable, Equatable, Hashable, Identifiable, Sendable {
        public var id: String { name }
        public var name: String

        public init(name: String) {
            self.name = SplitDNSConfiguration.normalizeDomain(name)
        }
    }

    public struct Exclusion: Codable, Equatable, Hashable, Identifiable, Sendable {
        public var id: String { name }
        public var name: String
        public var includesSubdomains: Bool

        public init(name: String, includesSubdomains: Bool = true) {
            self.name = SplitDNSConfiguration.normalizeDomain(name)
            self.includesSubdomains = includesSubdomains
        }
    }

    public var mode: Mode
    public var domains: [Domain]
    public var exclusions: [Exclusion]

    public static let allDomains = SplitDNSConfiguration(mode: .allDomains, domains: [], exclusions: [])

    public init(mode: Mode = .allDomains, domains: [Domain] = [], exclusions: [Exclusion] = []) {
        self.mode = mode
        self.domains = Self.deduplicateDomains(domains)
        self.exclusions = Self.deduplicateExclusions(exclusions)
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case domains
        case exclusions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedMode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .allDomains
        let decodedDomains = try container.decodeIfPresent([Domain].self, forKey: .domains) ?? []
        let decodedExclusions = try container.decodeIfPresent([Exclusion].self, forKey: .exclusions) ?? []
        self.init(mode: decodedMode, domains: decodedDomains, exclusions: decodedExclusions)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(domains, forKey: .domains)
        if !exclusions.isEmpty {
            try container.encode(exclusions, forKey: .exclusions)
        }
    }

    public var isDefault: Bool {
        mode == .allDomains && domains.isEmpty && exclusions.isEmpty
    }

    public var hasExclusions: Bool {
        !exclusions.isEmpty
    }

    public var normalizedDomainNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for domain in domains {
            let normalized = Self.normalizeDomain(domain.name)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }
        return result
    }

    public var normalizedExclusionNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for exclusion in exclusions {
            let normalized = Self.normalizeDomain(exclusion.name)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }
        return result
    }

    private static func deduplicateDomains(_ domains: [Domain]) -> [Domain] {
        var seen = Set<String>()
        var deduplicated: [Domain] = []
        for domain in domains {
            let normalized = normalizeDomain(domain.name)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            deduplicated.append(Domain(name: normalized))
        }
        return deduplicated
    }

    private static func deduplicateExclusions(_ exclusions: [Exclusion]) -> [Exclusion] {
        var seen = Set<String>()
        var deduplicated: [Exclusion] = []
        for exclusion in exclusions {
            let normalized = normalizeDomain(exclusion.name)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            deduplicated.append(Exclusion(name: normalized, includesSubdomains: exclusion.includesSubdomains))
        }
        return deduplicated
    }

    public static func normalizeDomain(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasSuffix(".") && !trimmed.hasSuffix("..") {
            trimmed.removeLast()
        }
        return trimmed
    }

    public enum DomainValidationError: Error, Equatable, LocalizedError, Sendable {
        case empty
        case invalidSyntax(String)
        case duplicate(String)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter a domain name such as hw45.nl."
            case .invalidSyntax(let value):
                return "\"\(value)\" is not a valid domain name. Use letters, numbers, hyphens, and dots without wildcards or ports."
            case .duplicate(let value):
                return "\"\(value)\" is already in the list."
            }
        }
    }

    public static func validateDomain(_ raw: String, existing: [Domain] = []) -> Result<String, DomainValidationError> {
        validateName(raw, existingNames: existing.map(\.name))
    }

    public static func validateExclusion(_ raw: String, existing: [Exclusion] = []) -> Result<String, DomainValidationError> {
        validateName(raw, existingNames: existing.map(\.name))
    }

    private static func validateName(_ raw: String, existingNames: [String]) -> Result<String, DomainValidationError> {
        let normalized = normalizeDomain(raw)
        guard !normalized.isEmpty else {
            return .failure(.empty)
        }
        guard isValidDomainName(normalized) else {
            return .failure(.invalidSyntax(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if existingNames.contains(where: { normalizeDomain($0) == normalized }) {
            return .failure(.duplicate(normalized))
        }
        return .success(normalized)
    }

    public static func isValidDomainName(_ raw: String) -> Bool {
        let domain = normalizeDomain(raw)
        guard !domain.isEmpty, domain.count <= 253 else { return false }
        guard !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        if IPAddress(domain) != nil {
            return false
        }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }

        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
            for scalar in label.unicodeScalars {
                let isLowerAlpha = scalar.value >= 97 && scalar.value <= 122
                let isDigit = scalar.value >= 48 && scalar.value <= 57
                let isHyphen = scalar.value == 45
                if !(isLowerAlpha || isDigit || isHyphen) {
                    return false
                }
            }
        }

        // Reject all-numeric final labels (RFC 1123 / avoids IPv4-like strings)
        if let lastLabel = labels.last, lastLabel.allSatisfy(\.isNumber) {
            return false
        }

        return true
    }

    public static func endpointDomainSuggestion(from endpoints: [Endpoint]) -> String? {
        for endpoint in endpoints {
            guard let hostname = endpoint.hostname else { continue }
            let normalized = normalizeDomain(hostname)
            if isValidDomainName(normalized) {
                return normalized
            }
        }
        return nil
    }

    public enum ValidationWarning: Equatable, Hashable, Identifiable, Sendable {
        case noDNSServer
        case dnsServerOutsideAllowedIPs([String])
        case exclusionOutsideMatchDomains(String)
        case exclusionCancelsDomain(String)

        public var id: String {
            switch self {
            case .noDNSServer:
                return "no-dns-server"
            case .dnsServerOutsideAllowedIPs(let servers):
                return "dns-outside-allowed-ips:\(servers.joined(separator: ","))"
            case .exclusionOutsideMatchDomains(let name):
                return "exclusion-outside-match-domains:\(name)"
            case .exclusionCancelsDomain(let name):
                return "exclusion-cancels-domain:\(name)"
            }
        }

        public var message: String {
            switch self {
            case .noDNSServer:
                return "Split DNS is enabled, but this tunnel has no DNS server configured in Interface."
            case .dnsServerOutsideAllowedIPs(let servers):
                let joined = servers.joined(separator: ", ")
                if servers.count == 1 {
                    return "DNS server \(joined) is outside the tunnel's Allowed IPs, so queries may not reach it."
                }
                return "DNS servers \(joined) are outside the tunnel's Allowed IPs, so queries may not reach them."
            case .exclusionOutsideMatchDomains(let name):
                return "\"\(name)\" is not under any tunnel DNS domain, so excluding it has no effect in this mode."
            case .exclusionCancelsDomain(let name):
                return "Excluding \"\(name)\" with subdomains cancels the tunnel DNS domain \"\(name)\". "
                    + "Use \"this name only\" to exclude only the apex."
            }
        }
    }

    public func validationWarnings(dnsServers: [IPAddress], allowedIPs: [IPPrefix]) -> [ValidationWarning] {
        guard mode == .onlyDomains else { return [] }
        var warnings: [ValidationWarning] = []

        if dnsServers.isEmpty {
            warnings.append(.noDNSServer)
        } else {
            let unreachableServers = dnsServers.filter { server in
                !allowedIPs.contains { prefix in prefix.contains(server) }
            }
            if !unreachableServers.isEmpty {
                warnings.append(.dnsServerOutsideAllowedIPs(unreachableServers.map(\.description)))
            }
        }

        let matchDomains = normalizedDomainNames
        let matchDomainSet = Set(matchDomains)
        for exclusion in exclusions {
            let name = Self.normalizeDomain(exclusion.name)
            guard !name.isEmpty else { continue }
            let coveredByTunnelDomain = matchDomains.contains { domain in
                name == domain || name.hasSuffix("." + domain)
            }
            if !coveredByTunnelDomain {
                warnings.append(.exclusionOutsideMatchDomains(name))
            } else if exclusion.includesSubdomains && matchDomainSet.contains(name) {
                warnings.append(.exclusionCancelsDomain(name))
            }
        }

        return warnings
    }

    public func validationWarnings(for profile: TunnelProfile) -> [ValidationWarning] {
        let allowedIPs = profile.peers.flatMap(\.allowedIPs)
        return validationWarnings(dnsServers: profile.interface.dnsServers, allowedIPs: allowedIPs)
    }

    public enum NormalDNSReason: Equatable, Hashable, Sendable {
        case noTunnelDNSServer
        case notInMatchDomains
        case excluded(Exclusion)
    }

    public enum DNSRouteDecision: Equatable, Hashable, Sendable {
        case tunnelDNS(matchedDomain: String?)
        case normalDNS(reason: NormalDNSReason)
    }

    public func routeDecision(for hostname: String, dnsServers: [IPAddress]) -> DNSRouteDecision {
        guard !dnsServers.isEmpty else {
            return .normalDNS(reason: .noTunnelDNSServer)
        }
        let normalizedQuery = Self.normalizeDomain(hostname)
        guard !normalizedQuery.isEmpty else {
            return mode == .allDomains
                ? .tunnelDNS(matchedDomain: nil)
                : .normalDNS(reason: .notInMatchDomains)
        }

        // Best matching tunnel DNS entry: in .allDomains mode there is an implicit wildcard (specificity 0).
        var bestTunnelMatch: (domain: String?, specificity: Int)?
        switch mode {
        case .allDomains:
            bestTunnelMatch = (domain: nil, specificity: 0)
        case .onlyDomains:
            for domain in normalizedDomainNames {
                if normalizedQuery == domain || normalizedQuery.hasSuffix("." + domain) {
                    if bestTunnelMatch == nil || domain.count > bestTunnelMatch!.specificity {
                        bestTunnelMatch = (domain: domain, specificity: domain.count)
                    }
                }
            }
        }

        // Best matching exclusion entry (applies in both modes).
        var bestExclusionMatch: (exclusion: Exclusion, specificity: Int)?
        for exclusion in exclusions {
            let name = Self.normalizeDomain(exclusion.name)
            guard !name.isEmpty else { continue }
            let matches: Bool
            if exclusion.includesSubdomains {
                matches = normalizedQuery == name || normalizedQuery.hasSuffix("." + name)
            } else {
                matches = normalizedQuery == name
            }
            if matches, bestExclusionMatch == nil || name.count > bestExclusionMatch!.specificity {
                let matchedExclusion = Exclusion(name: name, includesSubdomains: exclusion.includesSubdomains)
                bestExclusionMatch = (exclusion: matchedExclusion, specificity: name.count)
            }
        }

        switch (bestTunnelMatch, bestExclusionMatch) {
        case (.none, .none):
            return .normalDNS(reason: .notInMatchDomains)
        case (.none, .some(let excl)):
            return .normalDNS(reason: .excluded(excl.exclusion))
        case (.some(let tunnel), .none):
            return .tunnelDNS(matchedDomain: tunnel.domain)
        case (.some(let tunnel), .some(let excl)):
            // Most specific entry wins; on equal name length, exclusion wins.
            if excl.specificity >= tunnel.specificity {
                return .normalDNS(reason: .excluded(excl.exclusion))
            }
            return .tunnelDNS(matchedDomain: tunnel.domain)
        }
    }
}
