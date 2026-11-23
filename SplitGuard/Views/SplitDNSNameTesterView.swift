import SwiftUI
import WireGuardKit

struct SplitDNSWarningRow: View {
    let warning: SplitDNSConfiguration.ValidationWarning

    var body: some View {
        HStack(alignment: .top, spacing: SGSpacing.xSmall) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(SGColor.statusTransitioning)
                .padding(.top, 1)
            Text(warning.message)
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textPrimary)
        }
        .padding(.vertical, 2)
    }
}

struct SplitDNSRoutingPreviewView: View {
    let splitDNS: SplitDNSConfiguration
    let dnsServers: [DNSServer]

    private var vpnDNSLabel: String {
        if dnsServers.isEmpty {
            return "VPN DNS (none set)"
        }
        let joined = dnsServers.map(\.stringRepresentation).joined(separator: ", ")
        return "VPN DNS (\(joined))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xxSmall + 2) {
            Text("Routing Preview")
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textSecondary)

            switch splitDNS.mode {
            case .allDomains:
                previewRow(
                    left: "All lookups",
                    right: dnsServers.isEmpty ? "Normal DNS" : vpnDNSLabel,
                    usesTunnel: !dnsServers.isEmpty
                )
            case .onlyDomains:
                let domains = splitDNS.normalizedDomainNames
                if domains.isEmpty {
                    previewRow(left: "Everything", right: "Normal DNS", usesTunnel: false)
                } else {
                    ForEach(domains.prefix(3), id: \.self) { domain in
                        previewRow(
                            left: "\(domain), *.\(domain)",
                            right: vpnDNSLabel,
                            usesTunnel: !dnsServers.isEmpty
                        )
                    }
                    if domains.count > 3 {
                        Text("+\(domains.count - 3) more domain\(domains.count - 3 == 1 ? "" : "s") → \(vpnDNSLabel)")
                            .font(SGTypography.monoCompact)
                            .foregroundStyle(SGColor.textSecondary)
                    }
                    previewRow(left: "Everything else", right: "Normal DNS", usesTunnel: false)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func previewRow(left: String, right: String, usesTunnel: Bool) -> some View {
        HStack(spacing: SGSpacing.xxSmall) {
            Text(left)
                .font(SGTypography.monoCompact)
                .foregroundStyle(SGColor.textPrimary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(SGColor.textTertiary)
            Text(right)
                .font(SGTypography.monoCompact)
                .foregroundStyle(usesTunnel ? SGColor.accent : SGColor.textSecondary)
                .lineLimit(1)
        }
    }
}

struct SplitDNSNameTesterView: View {
    let splitDNS: SplitDNSConfiguration
    let dnsServers: [DNSServer]
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
            Text("Test a Name")
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textSecondary)

            HStack(spacing: SGSpacing.small) {
                TextField("e.g. ha.hw45.nl", text: $query)
                    .font(SGTypography.monoValue)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
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
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Test")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
        let tint: Color

        switch decision {
        case .tunnelDNS(let matchedDomain):
            let serverText = dnsServers.map(\.stringRepresentation).joined(separator: ", ")
            label = "VPN DNS (\(serverText))"
            detail = matchedDomain.map { "Matched \($0)" } ?? "All domains routed through tunnel"
            tint = SGColor.accent
        case .normalDNS(let reason):
            label = "Normal DNS"
            switch reason {
            case .noTunnelDNSServer:
                detail = "No tunnel DNS server configured"
            case .notInMatchDomains:
                detail = "Not in split DNS list"
            }
            tint = SGColor.textSecondary
        }

        return HStack(spacing: SGSpacing.xSmall) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(SGTypography.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(detail)
                    .font(SGTypography.metricLabel)
                    .foregroundStyle(SGColor.textSecondary)
            }
        }
    }

    private func lookupResultView(_ result: DNSLookupResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if result.succeeded {
                HStack(spacing: SGSpacing.xxSmall) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(SGColor.statusActive)
                    Text(result.addresses.joined(separator: ", "))
                        .font(SGTypography.monoCompact)
                        .foregroundStyle(SGColor.textPrimary)
                        .textSelection(.enabled)
                    Text("(\(result.durationMilliseconds) ms)")
                        .font(SGTypography.metricLabel)
                        .foregroundStyle(SGColor.textTertiary)
                }
            } else {
                HStack(spacing: SGSpacing.xxSmall) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(SGColor.statusError)
                    Text(result.errorMessage ?? "Could not resolve")
                        .font(SGTypography.caption)
                        .foregroundStyle(SGColor.statusError)
                }
            }

            if !isTunnelActive {
                Text("Tunnel is inactive — lookup used the current network's DNS.")
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
