import SplitGuardCore
import SwiftUI
import WireGuardEngine

struct SplitDNSExclusionListView: View {
    @Bindable var viewModel: TunnelEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
            Text("KEEP ON NORMAL DNS")
                .font(SGTypography.metricLabel)
                .tracking(0.8)
                .foregroundStyle(SGColor.textSecondary)

            if let suggestedExclusion = viewModel.suggestedEndpointExclusion {
                endpointExclusionSuggestionRow(domain: suggestedExclusion)
            }

            exclusionRows
            addExclusionRow

            if let errorText = viewModel.splitDNSExclusionInputError {
                Label(errorText, systemImage: "exclamationmark.circle.fill")
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.statusError)
            }

            Text(
                "Intercepts UDP port 53 queries using the current network's DNS. " +
                    "DNS over TCP and encrypted DNS are not intercepted, and routes still follow Allowed IPs."
            )
            .font(SGTypography.caption)
            .foregroundStyle(SGColor.textTertiary)
        }
    }

    private func endpointExclusionSuggestionRow(domain: String) -> some View {
        HStack(spacing: SGSpacing.small) {
            Image(systemName: "network")
                .font(.subheadline.weight(.black))
                .foregroundStyle(SGColor.inkOnPop)

            VStack(alignment: .leading, spacing: 2) {
                Text("Keep \(domain) on normal DNS?")
                    .font(SGTypography.subheadline)
                    .foregroundStyle(SGColor.inkOnPop)
                Text("Peer endpoint hostname")
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.inkOnPop.opacity(0.8))
            }

            Spacer(minLength: SGSpacing.xSmall)

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    viewModel.applySuggestedEndpointExclusion()
                }
            } label: {
                Text("EXCLUDE")
                    .font(SGTypography.displayCompact)
                    .tracking(0.8)
                    .padding(.horizontal, SGSpacing.small)
                    .padding(.vertical, 6)
            }
            .buttonStyle(
                BrutalistButtonStyle(
                    fill: SGColor.popYellow,
                    foreground: SGColor.inkOnPop,
                    borderWidth: SGBorder.thin,
                    shadowOffset: 2,
                    shadowColor: SGColor.shadowInk
                )
            )
        }
        .padding(SGSpacing.small)
        .background(SGColor.popPurple)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.regular))
    }

    @ViewBuilder
    private var exclusionRows: some View {
        if viewModel.splitDNSExclusions.isEmpty {
            Text("No excluded names")
                .font(SGTypography.subheadline)
                .foregroundStyle(SGColor.textTertiary)
        } else {
            ForEach(viewModel.splitDNSExclusions) { exclusion in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: SGSpacing.small) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exclusion.name)
                                .font(SGTypography.monoValue.weight(.semibold))
                                .foregroundStyle(SGColor.textPrimary)
                            Text(
                                exclusion.includesSubdomains
                                    ? "Matches \(exclusion.name) and *.\(exclusion.name)"
                                    : "Matches \(exclusion.name) only"
                            )
                            .font(SGTypography.caption)
                            .foregroundStyle(SGColor.textSecondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            withAnimation(.snappy(duration: 0.2)) {
                                viewModel.removeSplitDNSExclusion(named: exclusion.name)
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
                        .accessibilityLabel("Remove exclusion \(exclusion.name)")
                    }

                    HStack {
                        Text("Include subdomains")
                            .font(SGTypography.caption)
                            .foregroundStyle(SGColor.textSecondary)
                        Spacer()
                        BrutalistToggle(
                            isOn: exclusion.includesSubdomains,
                            activeTint: SGColor.popBlue,
                            isInteractive: true,
                            accessibilityLabelText: "Include subdomains for \(exclusion.name)"
                        ) { newValue in
                            viewModel.setSplitDNSExclusionIncludesSubdomains(newValue, for: exclusion.name)
                        }
                    }
                }
                .padding(SGSpacing.xSmall)
                .background(SGColor.surfaceElevated)
                .overlay(Rectangle().strokeBorder(SGColor.borderSubtle, lineWidth: 1))
            }
        }
    }

    private var addExclusionRow: some View {
        HStack(spacing: SGSpacing.small) {
            TextField("Add excluded name", text: $viewModel.newSplitDNSExclusion)
                .font(SGTypography.monoValue)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .padding(.horizontal, SGSpacing.xSmall)
                .padding(.vertical, 8)
                .background(SGColor.surfaceElevated)
                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
                .onChange(of: viewModel.newSplitDNSExclusion) { _, _ in
                    viewModel.splitDNSExclusionInputError = nil
                }
                .onSubmit {
                    _ = viewModel.addSplitDNSExclusion()
                }

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    _ = viewModel.addSplitDNSExclusion()
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
            .disabled(viewModel.newSplitDNSExclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

struct SplitDNSDetailCard: View {
    let splitDNS: SplitDNSConfiguration
    let dnsServers: [IPAddress]
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
                        .background(splitDNS.mode == .onlyDomains ? SGColor.popBlue : SGColor.popPurple)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))
                }

                if splitDNS.mode == .onlyDomains {
                    Text("USE VPN DNS FOR")
                        .font(SGTypography.metricLabel)
                        .tracking(0.8)
                        .foregroundStyle(SGColor.textSecondary)

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
                }

                if !splitDNS.exclusions.isEmpty {
                    Text("KEEP ON NORMAL DNS")
                        .font(SGTypography.metricLabel)
                        .tracking(0.8)
                        .foregroundStyle(SGColor.textSecondary)

                    VStack(spacing: SGSpacing.xSmall) {
                        ForEach(splitDNS.exclusions) { exclusion in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exclusion.name)
                                    .font(SGTypography.monoValue.weight(.semibold))
                                    .foregroundStyle(SGColor.textPrimary)
                                Text(
                                    exclusion.includesSubdomains
                                        ? "Matches \(exclusion.name) and *.\(exclusion.name)"
                                        : "Matches \(exclusion.name) only"
                                )
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
