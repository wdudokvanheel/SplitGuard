import SwiftUI
import WireGuardKit

struct SplitDNSWarningRow: View {
    let warning: SplitDNSConfiguration.ValidationWarning

    var body: some View {
        HStack(alignment: .top, spacing: SGSpacing.xSmall) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(SGColor.inkOnPop)
                .padding(.top, 1)
            Text(warning.message)
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.inkOnPop)
        }
        .padding(SGSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SGColor.popYellow)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
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
            Text("ROUTING PREVIEW")
                .font(SGTypography.metricLabel)
                .tracking(0.8)
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
            Text("TEST A NAME")
                .font(SGTypography.metricLabel)
                .tracking(0.8)
                .foregroundStyle(SGColor.textSecondary)

            HStack(spacing: SGSpacing.small) {
                TextField("e.g. ha.hw45.nl", text: $query)
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
                                Text("TEST")
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
            let serverText = dnsServers.map(\.stringRepresentation).joined(separator: ", ")
            label = "VPN DNS (\(serverText))"
            detail = matchedDomain.map { "Matched \($0)" } ?? "All domains routed through tunnel"
            fill = SGColor.popPurple
            onPop = true
        case .normalDNS(let reason):
            label = "Normal DNS"
            switch reason {
            case .noTunnelDNSServer:
                detail = "No tunnel DNS server configured"
            case .notInMatchDomains:
                detail = "Not in split DNS list"
            }
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
                    Text(result.errorMessage ?? "Could not resolve")
                        .font(SGTypography.caption)
                        .foregroundStyle(SGColor.pureWhite)
                }
                .padding(SGSpacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SGColor.popRed)
                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
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
