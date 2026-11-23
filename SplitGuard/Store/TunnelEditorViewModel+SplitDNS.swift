import Foundation
import WireGuardKit

extension TunnelEditorViewModel {
    var splitDNSConfiguration: SplitDNSConfiguration {
        SplitDNSConfiguration(mode: splitDNSMode, domains: splitDNSDomains)
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

    func applySuggestedEndpointDomain() {
        guard let suggested = suggestedEndpointDomain else { return }
        splitDNSMode = .onlyDomains
        if !splitDNSDomains.contains(where: { $0.name == suggested }) {
            splitDNSDomains.append(SplitDNSConfiguration.Domain(name: suggested))
        }
        splitDNSInputError = nil
    }

    func validateSplitDNSForSave() -> Result<SplitDNSConfiguration, AlertItem> {
        let pendingDomain = newSplitDNSDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        if splitDNSMode == .onlyDomains && !pendingDomain.isEmpty {
            if !addSplitDNSDomain() {
                return .failure(AlertItem(
                    title: "Invalid Split DNS Domain",
                    message: splitDNSInputError ?? "Enter a valid domain name."
                ))
            }
        }

        guard splitDNSMode == .onlyDomains else {
            return .success(SplitDNSConfiguration(mode: splitDNSMode, domains: splitDNSDomains))
        }

        if splitDNSDomains.isEmpty {
            return .failure(AlertItem(
                title: "Split DNS Domains Required",
                message: "Add at least one domain, or switch Split DNS to All domains."
            ))
        }

        var seen = Set<String>()
        for domain in splitDNSDomains {
            let normalized = SplitDNSConfiguration.normalizeDomain(domain.name)
            if !SplitDNSConfiguration.isValidDomainName(normalized) {
                return .failure(AlertItem(
                    title: "Invalid Split DNS Domain",
                    message: SplitDNSConfiguration.DomainValidationError.invalidSyntax(domain.name).localizedDescription
                ))
            }
            if seen.contains(normalized) {
                return .failure(AlertItem(
                    title: "Duplicate Split DNS Domain",
                    message: SplitDNSConfiguration.DomainValidationError.duplicate(normalized).localizedDescription
                ))
            }
            seen.insert(normalized)
        }

        return .success(SplitDNSConfiguration(mode: splitDNSMode, domains: splitDNSDomains))
    }
}
