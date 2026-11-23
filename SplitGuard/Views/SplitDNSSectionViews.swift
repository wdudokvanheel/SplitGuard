import SwiftUI
import WireGuardKit

struct SplitDNSEditorSection: View {
    @Bindable var viewModel: TunnelEditorViewModel
    let isTunnelActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(
                title: "Split DNS",
                trailingText: viewModel.splitDNSMode == .onlyDomains ? "SPLIT" : "ALL"
            )

            VStack(alignment: .leading, spacing: SGSpacing.small) {
                BrutalistSegmentedControl(
                    selection: $viewModel.splitDNSMode,
                    options: [
                        .init(value: .allDomains, title: "All domains", accent: SGColor.popBlue),
                        .init(value: .onlyDomains, title: "Only these domains", accent: SGColor.popPurple)
                    ]
                )
                .onChange(of: viewModel.splitDNSMode) { _, _ in
                    viewModel.splitDNSInputError = nil
                }

                Text(footerDescription)
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.textSecondary)

                if let suggested = viewModel.suggestedEndpointDomain {
                    suggestionRow(domain: suggested)
                }

                if viewModel.splitDNSMode == .onlyDomains {
                    Rectangle().fill(SGColor.borderSubtle).frame(height: 1)
                    domainRows
                    addDomainRow
                    if let errorText = viewModel.splitDNSInputError {
                        Label(errorText, systemImage: "exclamationmark.circle.fill")
                            .font(SGTypography.caption)
                            .foregroundStyle(SGColor.statusError)
                    }
                    ForEach(viewModel.splitDNSWarnings) { warning in
                        SplitDNSWarningRow(warning: warning)
                    }
                }

                Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                SplitDNSRoutingPreviewView(
                    splitDNS: viewModel.splitDNSConfiguration,
                    dnsServers: viewModel.currentDNSServers
                )

                Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                SplitDNSNameTesterView(
                    splitDNS: viewModel.splitDNSConfiguration,
                    dnsServers: viewModel.currentDNSServers,
                    isTunnelActive: isTunnelActive
                )
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private var footerDescription: String {
        switch viewModel.splitDNSMode {
        case .allDomains:
            return "Every DNS query uses the tunnel's DNS servers (standard WireGuard behavior)."
        case .onlyDomains:
            return "Only listed domains and their subdomains use the tunnel's DNS server. Everything else uses the network's normal DNS."
        }
    }

    private func suggestionRow(domain: String) -> some View {
        HStack(spacing: SGSpacing.small) {
            Image(systemName: "sparkles")
                .font(.subheadline.weight(.black))
                .foregroundStyle(SGColor.inkOnPop)

            VStack(alignment: .leading, spacing: 2) {
                Text("Use VPN DNS for \(domain) and its subdomains?")
                    .font(SGTypography.subheadline)
                    .foregroundStyle(SGColor.inkOnPop)
                Text("Detected from peer endpoint")
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.inkOnPop.opacity(0.8))
            }

            Spacer(minLength: SGSpacing.xSmall)

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    viewModel.applySuggestedEndpointDomain()
                }
            } label: {
                Text("USE")
                    .font(SGTypography.displayCompact)
                    .tracking(0.8)
                    .padding(.horizontal, SGSpacing.small)
                    .padding(.vertical, 8)
            }
            .buttonStyle(
                BrutalistButtonStyle(
                    fill: SGColor.popGreen,
                    foreground: SGColor.inkOnPop,
                    borderWidth: SGBorder.thin,
                    shadowOffset: 2,
                    shadowColor: SGColor.shadowInk
                )
            )
            .padding(.trailing, 2)
            .accessibilityLabel("Use VPN DNS for \(domain)")
        }
        .padding(SGSpacing.small)
        .background(SGColor.popPurple)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.regular))
    }

    @ViewBuilder
    private var domainRows: some View {
        if viewModel.splitDNSDomains.isEmpty {
            Text("No domains added yet")
                .font(SGTypography.subheadline)
                .foregroundStyle(SGColor.textTertiary)
        } else {
            ForEach(viewModel.splitDNSDomains) { domain in
                HStack(spacing: SGSpacing.small) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(domain.name)
                            .font(SGTypography.monoValue.weight(.semibold))
                            .foregroundStyle(SGColor.textPrimary)
                        Text("Matches \(domain.name) and *.\(domain.name)")
                            .font(SGTypography.caption)
                            .foregroundStyle(SGColor.textSecondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        withAnimation(.snappy(duration: 0.2)) {
                            viewModel.removeSplitDNSDomain(named: domain.name)
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.black))
                            .foregroundStyle(SGColor.pureWhite)
                            .frame(width: 26, height: 26)
                            .background(SGColor.popRed)
                            .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(domain.name)")
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var addDomainRow: some View {
        HStack(spacing: SGSpacing.small) {
            TextField("Add domain", text: $viewModel.newSplitDNSDomain)
                .font(SGTypography.monoValue)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .padding(.horizontal, SGSpacing.xSmall)
                .padding(.vertical, 8)
                .background(SGColor.surfaceElevated)
                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
                .onChange(of: viewModel.newSplitDNSDomain) { _, _ in
                    viewModel.splitDNSInputError = nil
                }
                .onSubmit {
                    _ = viewModel.addSplitDNSDomain()
                }

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    _ = viewModel.addSplitDNSDomain()
                }
            } label: {
                Text("ADD")
                    .font(SGTypography.displayCompact)
                    .tracking(0.8)
                    .padding(.horizontal, SGSpacing.small)
                    .padding(.vertical, 8)
            }
            .buttonStyle(
                BrutalistButtonStyle(
                    fill: SGColor.popYellow,
                    foreground: SGColor.inkOnPop,
                    borderWidth: SGBorder.regular,
                    shadowOffset: SGShadow.small
                )
            )
            .disabled(viewModel.newSplitDNSDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

struct SplitDNSDetailCard: View {
    let splitDNS: SplitDNSConfiguration
    let dnsServers: [DNSServer]
    let warnings: [SplitDNSConfiguration.ValidationWarning]
    let isTunnelActive: Bool

    private var modeLabel: String {
        switch splitDNS.mode {
        case .allDomains:
            return "ALL DOMAINS"
        case .onlyDomains:
            return "ONLY THESE DOMAINS"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(
                title: "Split DNS",
                trailingText: splitDNS.mode == .onlyDomains ? "SPLIT" : "ALL"
            )

            VStack(alignment: .leading, spacing: SGSpacing.small) {
                HStack {
                    Text("MODE")
                        .font(SGTypography.metricLabel)
                        .foregroundStyle(SGColor.textSecondary)
                    Spacer()
                    Text(modeLabel)
                        .font(SGTypography.badge)
                        .foregroundStyle(SGColor.inkOnPop)
                        .padding(.horizontal, SGSpacing.xSmall)
                        .padding(.vertical, 3)
                        .background(splitDNS.mode == .onlyDomains ? SGColor.popPurple : SGColor.popBlue)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))
                }

                if splitDNS.mode == .onlyDomains {
                    if splitDNS.domains.isEmpty {
                        Text("No domains configured")
                            .font(SGTypography.subheadline)
                            .foregroundStyle(SGColor.textTertiary)
                    } else {
                        VStack(spacing: SGSpacing.xSmall) {
                            ForEach(splitDNS.domains) { domain in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(domain.name)
                                        .font(SGTypography.monoValue.weight(.semibold))
                                        .foregroundStyle(SGColor.textPrimary)
                                    Text("Matches \(domain.name) and *.\(domain.name)")
                                        .font(SGTypography.caption)
                                        .foregroundStyle(SGColor.textSecondary)
                                }
                                .padding(SGSpacing.xSmall)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(SGColor.surfaceElevated)
                                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
                            }
                        }
                    }

                    ForEach(warnings) { warning in
                        SplitDNSWarningRow(warning: warning)
                    }
                }

                Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                SplitDNSRoutingPreviewView(splitDNS: splitDNS, dnsServers: dnsServers)

                Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                SplitDNSNameTesterView(
                    splitDNS: splitDNS,
                    dnsServers: dnsServers,
                    isTunnelActive: isTunnelActive
                )
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }
}
