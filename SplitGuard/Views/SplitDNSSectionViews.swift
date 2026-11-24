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
                        .init(value: .allDomains, title: "All domains", accent: SGColor.popPurple),
                        .init(value: .onlyDomains, title: "Only these domains", accent: SGColor.popBlue)
                    ]
                )
                .onChange(of: viewModel.splitDNSMode) { _, _ in
                    viewModel.splitDNSInputError = nil
                    viewModel.splitDNSExclusionInputError = nil
                }

                Text(footerDescription)
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.textSecondary)

                if let suggested = viewModel.suggestedEndpointDomain {
                    suggestionRow(domain: suggested)
                }

                Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                vpnDNSSubsection

                Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                SplitDNSExclusionListView(viewModel: viewModel)

                if !viewModel.splitDNSWarnings.isEmpty {
                    ForEach(viewModel.splitDNSWarnings) { warning in
                        warningRow(warning)
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
            return "Every DNS query uses the tunnel's DNS servers unless listed under Keep on normal DNS."
        case .onlyDomains:
            return "Only listed domains and their subdomains use the tunnel's DNS server. Everything else uses the network's normal DNS."
        }
    }

    @ViewBuilder
    private var vpnDNSSubsection: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
            Text("USE VPN DNS FOR")
                .font(SGTypography.metricLabel)
                .tracking(0.8)
                .foregroundStyle(SGColor.textSecondary)

            if viewModel.splitDNSMode == .allDomains {
                Text("All names use the VPN's DNS server")
                    .font(SGTypography.subheadline)
                    .foregroundStyle(SGColor.textPrimary)
            } else {
                domainRows
                addDomainRow
                if let errorText = viewModel.splitDNSInputError {
                    Label(errorText, systemImage: "exclamationmark.circle.fill")
                        .font(SGTypography.caption)
                        .foregroundStyle(SGColor.statusError)
                }
            }
        }
    }

    private func warningRow(_ warning: SplitDNSConfiguration.ValidationWarning) -> some View {
        switch warning {
        case .exclusionCancelsDomain(let name):
            return SplitDNSWarningRow(
                warning: warning,
                fixTitle: "THIS NAME ONLY",
                onFixAction: {
                    withAnimation(.snappy(duration: 0.2)) {
                        viewModel.setSplitDNSExclusionIncludesSubdomains(false, for: name)
                    }
                }
            )
        default:
            return SplitDNSWarningRow(warning: warning)
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
                Text("Detected from peer endpoint; keeps \(domain) itself on normal DNS")
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
        .background(SGColor.popBlue)
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
                VStack(alignment: .leading, spacing: 6) {
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

                    let apexExcluded = viewModel.isApexExcluded(for: domain.name)
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            viewModel.toggleApexExclusion(for: domain.name)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: apexExcluded ? "checkmark.square.fill" : "square")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(apexExcluded ? SGColor.popBlue : SGColor.textSecondary)
                            Text("Keep \(domain.name) itself on normal DNS")
                                .font(SGTypography.caption)
                                .foregroundStyle(SGColor.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(SGSpacing.xSmall)
                .background(SGColor.surfaceElevated)
                .overlay(Rectangle().strokeBorder(SGColor.borderSubtle, lineWidth: 1))
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
