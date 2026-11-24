import Foundation
import WireGuardKit

extension TunnelEditorViewModel {
    var splitDNSConfiguration: SplitDNSConfiguration {
        SplitDNSConfiguration(
            mode: splitDNSMode,
            domains: splitDNSDomains,
            exclusions: splitDNSExclusions
        )
    }

    var currentDNSServers: [DNSServer] {
        dns
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { DNSServer(from: $0) }
    }

    var currentAllowedIPs: [IPAddressRange] {
        _ = peerRevision
        return tunnelViewModel.peersData.flatMap { peerData in
            peerData[.allowedIPs]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap { IPAddressRange(from: $0) }
        }
    }

    var currentEndpointHostnames: Set<String> {
        _ = peerRevision
        let hostnames = tunnelViewModel.peersData.compactMap { peerData -> String? in
            let raw = peerData[.endpoint].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let endpoint = Endpoint(from: raw), let hostname = endpoint.hostname() else { return nil }
            let normalized = SplitDNSConfiguration.normalizeDomain(hostname)
            return SplitDNSConfiguration.isValidDomainName(normalized) ? normalized : nil
        }
        return Set(hostnames)
    }

    var suggestedEndpointDomain: String? {
        _ = peerRevision
        let endpoints = tunnelViewModel.peersData.compactMap { peerData in
            Endpoint(from: peerData[.endpoint].trimmingCharacters(in: .whitespacesAndNewlines))
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
        _ = peerRevision
        let endpoints = tunnelViewModel.peersData.compactMap { peerData in
            Endpoint(from: peerData[.endpoint].trimmingCharacters(in: .whitespacesAndNewlines))
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
            splitDNSInputError = SplitDNSConfiguration.DomainValidationError.empty.localizedDescription
            return false
        }

        var working = splitDNSDomains
        for candidate in candidates {
            switch SplitDNSConfiguration.validateDomain(candidate, existing: working) {
            case .success(let normalized):
                working.append(SplitDNSConfiguration.Domain(name: normalized))
            case .failure(let error):
                splitDNSInputError = error.localizedDescription
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
        splitDNSInputError = nil
    }

    @discardableResult
    func addSplitDNSExclusion(_ rawInput: String? = nil, includesSubdomains: Bool = true) -> Bool {
        let source = rawInput ?? newSplitDNSExclusion
        let candidates = source
            .split { $0 == "," || $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !candidates.isEmpty else {
            splitDNSExclusionInputError = SplitDNSConfiguration.DomainValidationError.empty.localizedDescription
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
                splitDNSExclusionInputError = error.localizedDescription
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
                title: "Invalid Split DNS Domain",
                message: splitDNSInputError ?? "Enter a valid domain name."
            )
        }

        let pendingExclusion = newSplitDNSExclusion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingExclusion.isEmpty && !addSplitDNSExclusion() {
            return AlertItem(
                title: "Invalid Normal DNS Exclusion",
                message: splitDNSExclusionInputError ?? "Enter a valid domain name."
            )
        }
        return nil
    }

    private func validateExclusionsList() -> AlertItem? {
        var seen = Set<String>()
        for exclusion in splitDNSExclusions {
            let normalized = SplitDNSConfiguration.normalizeDomain(exclusion.name)
            if !SplitDNSConfiguration.isValidDomainName(normalized) {
                let message = SplitDNSConfiguration.DomainValidationError.invalidSyntax(exclusion.name).localizedDescription
                return AlertItem(title: "Invalid Normal DNS Exclusion", message: message)
            }
            if !seen.insert(normalized).inserted {
                let message = SplitDNSConfiguration.DomainValidationError.duplicate(normalized).localizedDescription
                return AlertItem(title: "Duplicate Normal DNS Exclusion", message: message)
            }
        }
        return nil
    }

    private func validateDomainsList() -> AlertItem? {
        if splitDNSDomains.isEmpty {
            return AlertItem(
                title: "Split DNS Domains Required",
                message: "Add at least one domain, or switch Split DNS to All domains."
            )
        }
        var seen = Set<String>()
        for domain in splitDNSDomains {
            let normalized = SplitDNSConfiguration.normalizeDomain(domain.name)
            if !SplitDNSConfiguration.isValidDomainName(normalized) {
                let message = SplitDNSConfiguration.DomainValidationError.invalidSyntax(domain.name).localizedDescription
                return AlertItem(title: "Invalid Split DNS Domain", message: message)
            }
            if !seen.insert(normalized).inserted {
                let message = SplitDNSConfiguration.DomainValidationError.duplicate(normalized).localizedDescription
                return AlertItem(title: "Duplicate Split DNS Domain", message: message)
            }
        }
        return nil
    }
}
