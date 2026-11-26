import SplitGuardCore
import SwiftUI
import WireGuardEngine

struct SplitDNSWarningRow: View {
    let warning: SplitDNSConfiguration.ValidationWarning
    var fixTitle: String?
    var onFixAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
            HStack(alignment: .top, spacing: SGSpacing.xSmall) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(SGColor.inkOnPop)
                    .padding(.top, 1)
                Text(warning.localizedMessage)
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.inkOnPop)
            }
            if let fixTitle, let onFixAction {
                Button(action: onFixAction) {
                    Text(fixTitle)
                        .font(SGTypography.metricLabel)
                        .tracking(0.6)
                        .padding(.horizontal, SGSpacing.xSmall)
                        .padding(.vertical, 5)
                }
                .buttonStyle(
                    BrutalistButtonStyle(
                        fill: SGColor.pureWhite,
                        foreground: SGColor.inkOnPop,
                        borderWidth: SGBorder.thin,
                        shadowOffset: 2,
                        shadowColor: SGColor.shadowInk
                    )
                )
            }
        }
        .padding(SGSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SGColor.popYellow)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
    }
}

struct SplitDNSRoutingPreviewView: View {
    let splitDNS: SplitDNSConfiguration
    let dnsServers: [IPAddress]

    private var vpnDNSLabel: String {
        if dnsServers.isEmpty {
            return L10n.tr("splitDNS.preview.vpnDNSNone", defaultValue: "VPN DNS (none set)")
        }
        let joined = dnsServers.map(\.description).joined(separator: ", ")
        return L10n.tr("splitDNS.preview.vpnDNSServers", defaultValue: "VPN DNS (\(joined))")
    }

    private var normalDNSLabel: String {
        L10n.tr("splitDNS.preview.normalDNS", defaultValue: "Normal DNS")
    }

    private var exactExclusionNames: Set<String> {
        Set(splitDNS.exclusions.filter { !$0.includesSubdomains }.map(\.name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xxSmall + 2) {
            Text(L10n.tr("splitDNS.preview.title", defaultValue: "Routing preview").uppercased())
                .font(SGTypography.metricLabel)
                .tracking(0.8)
                .foregroundStyle(SGColor.textSecondary)

            switch splitDNS.mode {
            case .allDomains:
                exclusionPreviewRows
                previewRow(
                    left: splitDNS.exclusions.isEmpty
                        ? L10n.tr("splitDNS.preview.allLookups", defaultValue: "All lookups")
                        : L10n.tr("splitDNS.preview.everythingElse", defaultValue: "Everything else"),
                    right: dnsServers.isEmpty ? normalDNSLabel : vpnDNSLabel,
                    usesTunnel: !dnsServers.isEmpty
                )
            case .onlyDomains:
                let domains = splitDNS.normalizedDomainNames
                if domains.isEmpty {
                    previewRow(
                        left: L10n.tr("splitDNS.preview.everything", defaultValue: "Everything"),
                        right: normalDNSLabel,
                        usesTunnel: false
                    )
                } else {
                    ForEach(domains.prefix(3), id: \.self) { domain in
                        let label = exactExclusionNames.contains(domain)
                            ? "*.\(domain)"
                            : "\(domain), *.\(domain)"
                        previewRow(
                            left: label,
                            right: vpnDNSLabel,
                            usesTunnel: !dnsServers.isEmpty
                        )
                    }
                    if domains.count > 3 {
                        let extra = domains.count - 3
                        Text(
                            L10n.tr(
                                "splitDNS.preview.moreDomains",
                                defaultValue: "+\(extra) more domains → \(vpnDNSLabel)"
                            )
                        )
                            .font(SGTypography.monoCompact)
                            .foregroundStyle(SGColor.textSecondary)
                    }
                    exclusionPreviewRows
                    previewRow(
                        left: L10n.tr("splitDNS.preview.everythingElse", defaultValue: "Everything else"),
                        right: normalDNSLabel,
                        usesTunnel: false
                    )
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var exclusionPreviewRows: some View {
        let exclusions = splitDNS.exclusions
        ForEach(exclusions.prefix(3)) { exclusion in
            let label = exclusion.includesSubdomains
                ? "\(exclusion.name), *.\(exclusion.name)"
                : exclusion.name
            previewRow(left: label, right: normalDNSLabel, usesTunnel: false)
        }
        if exclusions.count > 3 {
            let extra = exclusions.count - 3
            Text(
                L10n.tr(
                    "splitDNS.preview.moreExcluded",
                    defaultValue: "+\(extra) more excluded → Normal DNS"
                )
            )
                .font(SGTypography.monoCompact)
                .foregroundStyle(SGColor.textSecondary)
        }
    }

    private func previewRow(left: String, right: String, usesTunnel: Bool) -> some View {
        HStack(spacing: SGSpacing.xxSmall) {
            Text(left)
                .font(SGTypography.monoCompact)
                .foregroundStyle(SGColor.textPrimary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.black))
                .foregroundStyle(SGColor.textSecondary)
            Text(right)
                .font(SGTypography.monoCompact.weight(.semibold))
                .foregroundStyle(usesTunnel ? SGColor.inkOnPop : SGColor.textSecondary)
                .padding(.horizontal, usesTunnel ? 5 : 0)
                .padding(.vertical, usesTunnel ? 2 : 0)
                .background(usesTunnel ? SGColor.popGreen : Color.clear)
                .overlay {
                    if usesTunnel {
                        Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1)
                    }
                }
                .lineLimit(1)
        }
    }
}

struct SplitDNSNameTesterView: View {
    let splitDNS: SplitDNSConfiguration
    let dnsServers: [IPAddress]
    let isTunnelActive: Bool

    @State private var query = ""
    @State private var isTesting = false
    @State private var lookupResult: DNSLookupResult?

    private var normalizedQuery: String {
        SplitDNSConfiguration.normalizeDomain(query)
    }

    private var predictedRoute: SplitDNSConfiguration.DNSRouteDecision? {
        guard !normalizedQuery.isEmpty else { return nil }
        return splitDNS.routeDecision(for: normalizedQuery, dnsServers: dnsServers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
            Text(L10n.tr("splitDNS.tester.title", defaultValue: "Test a name").uppercased())
                .font(SGTypography.metricLabel)
                .tracking(0.8)
                .foregroundStyle(SGColor.textSecondary)

            HStack(spacing: SGSpacing.small) {
                TextField(
                    L10n.tr("splitDNS.tester.placeholder", defaultValue: "Enter hostname"),
                    text: $query
                )
                    .font(SGTypography.monoValue)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .padding(.horizontal, SGSpacing.xSmall)
                    .padding(.vertical, 8)
                    .background(SGColor.surfaceElevated)
                    .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
                    .onChange(of: query) { _, _ in
                        if lookupResult?.hostname != normalizedQuery {
                            lookupResult = nil
                        }
                    }
                    .onSubmit {
                        runLookup()
                    }

                Button {
                    runLookup()
                } label: {
                    Group {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(SGColor.pureWhite)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "magnifyingglass")
                                    .font(.caption.weight(.black))
                                Text(L10n.tr("splitDNS.tester.button", defaultValue: "Test").uppercased())
                                    .font(SGTypography.displayCompact)
                                    .tracking(0.8)
                            }
                        }
                    }
                    .padding(.horizontal, SGSpacing.small)
                    .padding(.vertical, 8)
                }
                .buttonStyle(
                    BrutalistButtonStyle(
                        fill: SGColor.popPink,
                        foreground: SGColor.pureWhite,
                        borderWidth: SGBorder.regular,
                        shadowOffset: SGShadow.small,
                        showGrain: true
                    )
                )
                .disabled(normalizedQuery.isEmpty || isTesting)
            }

            if let decision = predictedRoute {
                routeBadgeRow(decision)
            }

            if let lookupResult {
                lookupResultView(lookupResult)
            }
        }
        .padding(.vertical, 2)
    }

    private func routeBadgeRow(_ decision: SplitDNSConfiguration.DNSRouteDecision) -> some View {
        let label: String
        let detail: String
        let fill: Color
        let onPop: Bool

        switch decision {
        case .tunnelDNS(let matchedDomain):
            let serverText = dnsServers.map(\.description).joined(separator: ", ")
            label = L10n.tr("splitDNS.preview.vpnDNSServers", defaultValue: "VPN DNS (\(serverText))")
            detail = matchedDomain.map {
                L10n.tr("splitDNS.tester.matchedDomain", defaultValue: "Matched \($0)")
            } ?? L10n.tr("splitDNS.tester.allDomainsRouted", defaultValue: "All domains routed through tunnel")
            fill = SGColor.popBlue
            onPop = true
        case .normalDNS(let reason):
            label = L10n.tr("splitDNS.preview.normalDNS", defaultValue: "Normal DNS")
            detail = normalDNSDetail(for: reason)
            fill = SGColor.surfaceElevated
            onPop = false
        }

        return HStack(spacing: SGSpacing.xSmall) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption.weight(.black))
                .foregroundStyle(onPop ? SGColor.inkOnPop : SGColor.textPrimary)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(SGTypography.caption.weight(.bold))
                    .foregroundStyle(onPop ? SGColor.inkOnPop : SGColor.textPrimary)
                Text(detail)
                    .font(SGTypography.metricLabel)
                    .foregroundStyle(onPop ? SGColor.inkOnPop.opacity(0.8) : SGColor.textSecondary)
            }
        }
        .padding(SGSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
    }

    private func normalDNSDetail(for reason: SplitDNSConfiguration.NormalDNSReason) -> String {
        switch reason {
        case .noTunnelDNSServer:
            return L10n.tr("splitDNS.tester.noTunnelDNSServer", defaultValue: "No tunnel DNS server configured")
        case .notInMatchDomains:
            return L10n.tr("splitDNS.tester.notInList", defaultValue: "Not in split DNS list")
        case .excluded(let exclusion):
            return exclusion.includesSubdomains
                ? L10n.tr(
                    "splitDNS.tester.excludedWithSubdomains",
                    defaultValue: "Excluded (\(exclusion.name) and subdomains)"
                )
                : L10n.tr("splitDNS.tester.excludedOnly", defaultValue: "Excluded (\(exclusion.name) only)")
        }
    }

    private func lookupResultView(_ result: DNSLookupResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if result.succeeded {
                HStack(spacing: SGSpacing.xxSmall) {
                    Image(systemName: "checkmark.square.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(SGColor.inkOnPop)
                    Text(result.addresses.joined(separator: ", "))
                        .font(SGTypography.monoCompact.weight(.semibold))
                        .foregroundStyle(SGColor.inkOnPop)
                        .textSelection(.enabled)
                    Text("(\(result.durationMilliseconds) ms)")
                        .font(SGTypography.metricLabel)
                        .foregroundStyle(SGColor.inkOnPop.opacity(0.75))
                }
                .padding(SGSpacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SGColor.popGreen)
                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
            } else {
                HStack(spacing: SGSpacing.xxSmall) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(SGColor.pureWhite)
                    Text(
                        result.errorMessage
                            ?? L10n.tr("splitDNS.tester.couldNotResolve", defaultValue: "Could not resolve")
                    )
                        .font(SGTypography.caption)
                        .foregroundStyle(SGColor.pureWhite)
                }
                .padding(SGSpacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SGColor.popRed)
                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
            }

            if !isTunnelActive {
                Text(
                    L10n.tr(
                        "splitDNS.tester.inactiveHint",
                        defaultValue: "Tunnel is inactive — lookup used the current network's DNS."
                    )
                )
                    .font(SGTypography.metricLabel)
                    .foregroundStyle(SGColor.textTertiary)
            }
        }
    }

    private func runLookup() {
        let host = normalizedQuery
        guard !host.isEmpty else { return }
        isTesting = true
        Task {
            let result = await DNSLookupService.resolve(hostname: host)
            await MainActor.run {
                if normalizedQuery == host {
                    lookupResult = result
                }
                isTesting = false
            }
        }
    }
}
