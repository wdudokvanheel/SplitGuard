// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore
import WireGuardEngine

extension TunnelEditorViewModel {
    var splitDNSConfiguration: SplitDNSConfiguration {
        SplitDNSConfiguration(
            mode: splitDNSMode,
            domains: splitDNSDomains,
            exclusions: splitDNSExclusions
        )
    }

    var currentDNSServers: [IPAddress] {
        AllowedIPHelpers.splitCommaSeparated(draft.interface.dns).compactMap { item in
            guard let address = IPAddress(item), address.zoneID == nil else { return nil }
            return address
        }
    }

    var currentAllowedIPs: [IPPrefix] {
        draft.peers.flatMap { peer in
            AllowedIPHelpers.splitCommaSeparated(peer.allowedIPs)
                .compactMap { InterfaceAddress($0)?.network }
        }
    }

    var currentEndpointHostnames: Set<String> {
        let hostnames = draft.peers.compactMap { peer -> String? in
            let raw = peer.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let endpoint = Endpoint(raw), let hostname = endpoint.hostname else { return nil }
            let normalized = SplitDNSConfiguration.normalizeDomain(hostname)
            return SplitDNSConfiguration.isValidDomainName(normalized) ? normalized : nil
        }
        return Set(hostnames)
    }

    var suggestedEndpointDomain: String? {
        let endpoints = draft.peers.compactMap { peer in
            Endpoint(peer.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let suggested = SplitDNSConfiguration.endpointDomainSuggestion(from: endpoints) else {
            return nil
        }
        let alreadyIncluded = splitDNSMode == .onlyDomains &&
            splitDNSDomains.contains { $0.name == suggested }
        return alreadyIncluded ? nil : suggested
    }

    var suggestedEndpointExclusion: String? {
        guard splitDNSMode == .allDomains else { return nil }
        let endpoints = draft.peers.compactMap { peer in
            Endpoint(peer.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let suggested = SplitDNSConfiguration.endpointDomainSuggestion(from: endpoints) else {
            return nil
        }
        let alreadyExcluded = splitDNSExclusions.contains { $0.name == suggested }
        return alreadyExcluded ? nil : suggested
    }

    var splitDNSWarnings: [SplitDNSConfiguration.ValidationWarning] {
        splitDNSConfiguration.validationWarnings(
            dnsServers: currentDNSServers,
            allowedIPs: currentAllowedIPs
        )
    }

    @discardableResult
    func addSplitDNSDomain(_ rawInput: String? = nil) -> Bool {
        let source = rawInput ?? newSplitDNSDomain
        let candidates = source
            .split { $0 == "," || $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !candidates.isEmpty else {
            splitDNSInputError = SplitDNSConfiguration.DomainValidationError.empty.localizedMessage
            return false
        }

        var working = splitDNSDomains
        for candidate in candidates {
            switch SplitDNSConfiguration.validateDomain(candidate, existing: working) {
            case .success(let normalized):
                working.append(SplitDNSConfiguration.Domain(name: normalized))
            case .failure(let error):
                splitDNSInputError = error.localizedMessage
                return false
            }
        }

        splitDNSDomains = working
        splitDNSInputError = nil
        if rawInput == nil {
            newSplitDNSDomain = ""
        }
        return true
    }

    func removeSplitDNSDomain(named name: String) {
        let normalized = SplitDNSConfiguration.normalizeDomain(name)
        splitDNSDomains.removeAll { $0.name == normalized }
        // An exact-name exclusion only expressed this domain's "subdomains only" scope.
        splitDNSExclusions.removeAll { $0.name == normalized && !$0.includesSubdomains }
        splitDNSInputError = nil
    }

    /// Sets whether a VPN DNS domain also covers the name itself, or only its subdomains.
    func setSplitDNSDomainIncludesApex(_ includesApex: Bool, for domainName: String) {
        guard isApexExcluded(for: domainName) == includesApex else { return }
        toggleApexExclusion(for: domainName)
    }

    /// Exceptions shown in the editor. In "only these domains" mode, exact-name exclusions of a
    /// listed domain are presented as that domain's scope instead of as a separate exception.
    var visibleSplitDNSExceptions: [SplitDNSConfiguration.Exclusion] {
        guard splitDNSMode == .onlyDomains else { return splitDNSExclusions }
        let domainNames = Set(splitDNSDomains.map(\.name))
        return splitDNSExclusions.filter { $0.includesSubdomains || !domainNames.contains($0.name) }
    }

    var dnsServerWarnings: [SplitDNSConfiguration.ValidationWarning] {
        splitDNSWarnings.filter { warning in
            switch warning {
            case .noDNSServer, .dnsServerOutsideAllowedIPs:
                return true
            case .exclusionOutsideMatchDomains, .exclusionCancelsDomain:
                return false
            }
        }
    }

    var exceptionWarnings: [SplitDNSConfiguration.ValidationWarning] {
        splitDNSWarnings.filter { !dnsServerWarnings.contains($0) }
    }

    @discardableResult
    func addSplitDNSExclusion(_ rawInput: String? = nil, includesSubdomains: Bool = true) -> Bool {
        let source = rawInput ?? newSplitDNSExclusion
        let candidates = source
            .split { $0 == "," || $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !candidates.isEmpty else {
            splitDNSExclusionInputError = SplitDNSConfiguration.DomainValidationError.empty.localizedMessage
            return false
        }

        var working = splitDNSExclusions
        for candidate in candidates {
            switch SplitDNSConfiguration.validateExclusion(candidate, existing: working) {
            case .success(let normalized):
                working.append(SplitDNSConfiguration.Exclusion(
                    name: normalized,
                    includesSubdomains: includesSubdomains
                ))
            case .failure(let error):
                splitDNSExclusionInputError = error.localizedMessage
                return false
            }
        }

        splitDNSExclusions = working
        splitDNSExclusionInputError = nil
        if rawInput == nil {
            newSplitDNSExclusion = ""
        }
        return true
    }

    func removeSplitDNSExclusion(named name: String) {
        let normalized = SplitDNSConfiguration.normalizeDomain(name)
        splitDNSExclusions.removeAll { $0.name == normalized }
        splitDNSExclusionInputError = nil
    }

    func setSplitDNSExclusionIncludesSubdomains(_ includesSubdomains: Bool, for name: String) {
        let normalized = SplitDNSConfiguration.normalizeDomain(name)
        guard let index = splitDNSExclusions.firstIndex(where: { $0.name == normalized }) else { return }
        splitDNSExclusions[index].includesSubdomains = includesSubdomains
    }

    func isApexExcluded(for domainName: String) -> Bool {
        let normalized = SplitDNSConfiguration.normalizeDomain(domainName)
        return splitDNSExclusions.contains { $0.name == normalized && !$0.includesSubdomains }
    }

    func toggleApexExclusion(for domainName: String) {
        let normalized = SplitDNSConfiguration.normalizeDomain(domainName)
        if let index = splitDNSExclusions.firstIndex(where: { $0.name == normalized }) {
            if !splitDNSExclusions[index].includesSubdomains {
                splitDNSExclusions.remove(at: index)
            } else {
                splitDNSExclusions[index].includesSubdomains = false
            }
        } else {
            splitDNSExclusions.append(SplitDNSConfiguration.Exclusion(name: normalized, includesSubdomains: false))
        }
        splitDNSExclusionInputError = nil
    }

    func applySuggestedEndpointDomain() {
        guard let suggested = suggestedEndpointDomain else { return }
        splitDNSMode = .onlyDomains
        if !splitDNSDomains.contains(where: { $0.name == suggested }) {
            splitDNSDomains.append(SplitDNSConfiguration.Domain(name: suggested))
        }
        if currentEndpointHostnames.contains(suggested),
           !splitDNSExclusions.contains(where: { $0.name == suggested }) {
            splitDNSExclusions.append(SplitDNSConfiguration.Exclusion(name: suggested, includesSubdomains: false))
        }
        splitDNSInputError = nil
    }

    func applySuggestedEndpointExclusion() {
        guard let suggested = suggestedEndpointExclusion else { return }
        if !splitDNSExclusions.contains(where: { $0.name == suggested }) {
            splitDNSExclusions.append(SplitDNSConfiguration.Exclusion(name: suggested, includesSubdomains: false))
        }
        splitDNSExclusionInputError = nil
    }

    func validateSplitDNSForSave() -> Result<SplitDNSConfiguration, AlertItem> {
        if let pendingError = commitPendingSplitDNSInputs() {
            return .failure(pendingError)
        }
        if let exclusionError = validateExclusionsList() {
            return .failure(exclusionError)
        }
        if splitDNSMode == .onlyDomains, let domainError = validateDomainsList() {
            return .failure(domainError)
        }
        return .success(SplitDNSConfiguration(
            mode: splitDNSMode,
            domains: splitDNSDomains,
            exclusions: splitDNSExclusions
        ))
    }

    private func commitPendingSplitDNSInputs() -> AlertItem? {
        let pendingDomain = newSplitDNSDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        if splitDNSMode == .onlyDomains && !pendingDomain.isEmpty && !addSplitDNSDomain() {
            return AlertItem(
                title: L10n.tr("splitDNS.alert.invalidDomain.title", defaultValue: "Invalid Split DNS Domain"),
                message: splitDNSInputError
                    ?? L10n.tr("splitDNS.alert.enterValidDomain", defaultValue: "Enter a valid domain name.")
            )
        }

        let pendingExclusion = newSplitDNSExclusion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingExclusion.isEmpty && !addSplitDNSExclusion() {
            return AlertItem(
                title: L10n.tr("splitDNS.alert.invalidExclusion.title", defaultValue: "Invalid Normal DNS Exclusion"),
                message: splitDNSExclusionInputError
                    ?? L10n.tr("splitDNS.alert.enterValidDomain", defaultValue: "Enter a valid domain name.")
            )
        }
        return nil
    }

    private func validateExclusionsList() -> AlertItem? {
        var seen = Set<String>()
        for exclusion in splitDNSExclusions {
            let normalized = SplitDNSConfiguration.normalizeDomain(exclusion.name)
            if !SplitDNSConfiguration.isValidDomainName(normalized) {
                let message = SplitDNSConfiguration.DomainValidationError.invalidSyntax(exclusion.name).localizedMessage
                return AlertItem(
                    title: L10n.tr(
                        "splitDNS.alert.invalidExclusion.title",
                        defaultValue: "Invalid Normal DNS Exclusion"
                    ),
                    message: message
                )
            }
            if !seen.insert(normalized).inserted {
                let message = SplitDNSConfiguration.DomainValidationError.duplicate(normalized).localizedMessage
                return AlertItem(
                    title: L10n.tr(
                        "splitDNS.alert.duplicateExclusion.title",
                        defaultValue: "Duplicate Normal DNS Exclusion"
                    ),
                    message: message
                )
            }
        }
        return nil
    }

    private func validateDomainsList() -> AlertItem? {
        if splitDNSDomains.isEmpty {
            return AlertItem(
                title: L10n.tr("splitDNS.alert.domainsRequired.title", defaultValue: "Split DNS Domains Required"),
                message: L10n.tr(
                    "splitDNS.alert.domainsRequired.message",
                    defaultValue: "Add at least one domain, or switch Split DNS to All domains."
                )
            )
        }
        var seen = Set<String>()
        for domain in splitDNSDomains {
            let normalized = SplitDNSConfiguration.normalizeDomain(domain.name)
            if !SplitDNSConfiguration.isValidDomainName(normalized) {
                let message = SplitDNSConfiguration.DomainValidationError.invalidSyntax(domain.name).localizedMessage
                return AlertItem(
                    title: L10n.tr("splitDNS.alert.invalidDomain.title", defaultValue: "Invalid Split DNS Domain"),
                    message: message
                )
            }
            if !seen.insert(normalized).inserted {
                let message = SplitDNSConfiguration.DomainValidationError.duplicate(normalized).localizedMessage
                return AlertItem(
                    title: L10n.tr("splitDNS.alert.duplicateDomain.title", defaultValue: "Duplicate Split DNS Domain"),
                    message: message
                )
            }
        }
        return nil
    }
}
