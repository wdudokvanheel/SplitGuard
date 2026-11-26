import SplitGuardCore
import SwiftUI

/// The DNS tab of the tunnel editor: servers, split DNS mode, domains, exceptions and a tester,
/// each in its own card so only what applies to the chosen mode is shown.
struct SplitDNSEditorSection: View {
    @Bindable var viewModel: TunnelEditorViewModel
    let isTunnelActive: Bool

    var body: some View {
        DNSServersEditorCard(viewModel: viewModel)
        SplitDNSModeCard(viewModel: viewModel)

        if viewModel.splitDNSMode == .onlyDomains {
            SplitDNSDomainsCard(viewModel: viewModel)
        }

        SplitDNSExceptionsCard(viewModel: viewModel)

        EditorCard(title: L10n.tr("splitDNS.checkRouting.title", defaultValue: "Check routing")) {
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
    }
}

// MARK: - DNS Servers

struct DNSServersEditorCard: View {
    @Bindable var viewModel: TunnelEditorViewModel

    private var serverCountText: String {
        let count = viewModel.currentDNSServers.count
        return count == 0 ? L10n.tr("common.none", defaultValue: "None") : "\(count)"
    }

    var body: some View {
        EditorCard(
            title: L10n.tr("splitDNS.dnsServers.title", defaultValue: "DNS Servers"),
            trailingText: serverCountText,
            trailingFill: viewModel.currentDNSServers.isEmpty ? SGColor.surfaceElevated : SGColor.popGreen,
            trailingForeground: viewModel.currentDNSServers.isEmpty ? SGColor.textPrimary : SGColor.inkOnPop
        ) {
            EditorTextRow(
                label: L10n.tr("splitDNS.dnsServers.addressesLabel", defaultValue: "Server addresses"),
                placeholder: viewModel.shouldStronglyRecommendDNS
                    ? L10n.tr(
                        "tunnel.editor.placeholder.stronglyRecommended",
                        defaultValue: "Strongly recommended"
                    )
                    : L10n.tr("tunnel.editor.placeholder.optional", defaultValue: "Optional"),
                text: Binding(get: { viewModel.dns }, set: { viewModel.updateDNS($0) }),
                hasError: viewModel.interfaceErrorFields.contains(.dns),
                isMonospaced: true,
                keyboardType: .numbersAndPunctuation
            )

            Text(
                L10n.tr(
                    "splitDNS.dnsServers.help",
                    defaultValue: "The VPN's DNS servers, separated by commas. Lookups routed through the VPN use these."
                )
            )
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textSecondary)

            ForEach(viewModel.dnsServerWarnings) { warning in
                SplitDNSWarningRow(warning: warning)
            }
        }
    }
}

// MARK: - Mode

struct SplitDNSModeCard: View {
    @Bindable var viewModel: TunnelEditorViewModel

    var body: some View {
        EditorCard(
            title: L10n.tr("splitDNS.title", defaultValue: "Split DNS"),
            trailingText: viewModel.splitDNSMode == .onlyDomains
                ? L10n.tr("splitDNS.badge.split", defaultValue: "Split")
                : L10n.tr("splitDNS.badge.all", defaultValue: "All"),
            trailingFill: viewModel.splitDNSMode == .onlyDomains ? SGColor.popBlue : SGColor.popPurple
        ) {
            Text(L10n.tr("splitDNS.question", defaultValue: "Which lookups use the VPN's DNS?").uppercased())
                .font(SGTypography.metricLabel)
                .tracking(0.8)
                .foregroundStyle(SGColor.textSecondary)

            VStack(spacing: 0) {
                modeOption(
                    .allDomains,
                    title: L10n.tr("splitDNS.mode.allDomains", defaultValue: "All domains"),
                    subtitle: L10n.tr(
                        "splitDNS.mode.allDomains.subtitle",
                        defaultValue: "Every lookup uses the VPN's DNS, like the official WireGuard app."
                    ),
                    systemImage: "globe",
                    accent: SGColor.popPurple
                )
                Rectangle().fill(SGColor.borderInk).frame(height: SGBorder.thin)
                modeOption(
                    .onlyDomains,
                    title: L10n.tr("splitDNS.mode.onlyDomains", defaultValue: "Only selected domains"),
                    subtitle: L10n.tr(
                        "splitDNS.mode.onlyDomains.subtitle",
                        defaultValue: "Only the domains you add use the VPN's DNS. Everything else uses your network's normal DNS."
                    ),
                    systemImage: "arrow.triangle.branch",
                    accent: SGColor.popBlue
                )
            }
            .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))

            if viewModel.splitDNSMode == .allDomains, let suggested = viewModel.suggestedEndpointDomain {
                SplitDNSEndpointSuggestion(domain: suggested) {
                    withAnimation(.snappy(duration: 0.2)) {
                        viewModel.applySuggestedEndpointDomain()
                    }
                }
            }
        }
    }

    private func modeOption(
        _ mode: SplitDNSConfiguration.Mode,
        title: String,
        subtitle: String,
        systemImage: String,
        accent: Color
    ) -> some View {
        let isSelected = viewModel.splitDNSMode == mode
        return Button {
            guard !isSelected else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.snappy(duration: 0.2)) {
                viewModel.splitDNSMode = mode
                viewModel.splitDNSInputError = nil
                viewModel.splitDNSExclusionInputError = nil
            }
        } label: {
            HStack(alignment: .top, spacing: SGSpacing.small) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.black))
                    .frame(width: 30, height: 30)
                    .background(isSelected ? accent : SGColor.surfaceCard)
                    .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
                    .foregroundStyle(isSelected ? SGColor.inkOnPop : SGColor.textPrimary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SGTypography.bodyBold)
                        .foregroundStyle(SGColor.textPrimary)
                    Text(subtitle)
                        .font(SGTypography.caption)
                        .foregroundStyle(SGColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    Rectangle()
                        .fill(isSelected ? accent : SGColor.surfaceCard)
                        .frame(width: 22, height: 22)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.black))
                            .foregroundStyle(SGColor.inkOnPop)
                    }
                }
                .padding(.top, 4)
            }
            .padding(SGSpacing.small)
            .background(isSelected ? SGColor.surfaceElevated : SGColor.surfaceCard)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - VPN DNS Domains

struct SplitDNSDomainsCard: View {
    @Bindable var viewModel: TunnelEditorViewModel

    var body: some View {
        EditorCard(
            title: L10n.tr("splitDNS.domains.title", defaultValue: "VPN DNS Domains"),
            trailingText: "\(viewModel.splitDNSDomains.count)",
            trailingFill: viewModel.splitDNSDomains.isEmpty ? SGColor.popRed : SGColor.popBlue
        ) {
            if let suggested = viewModel.suggestedEndpointDomain {
                SplitDNSEndpointSuggestion(domain: suggested) {
                    withAnimation(.snappy(duration: 0.2)) {
                        viewModel.applySuggestedEndpointDomain()
                    }
                }
            }

            if viewModel.splitDNSDomains.isEmpty {
                SplitDNSEmptyState(
                    systemImage: "network",
                    message: L10n.tr(
                        "splitDNS.domains.emptyEditor",
                        defaultValue: "Add the domains of the services you reach through this VPN, like home.lan or corp.example.com."
                    )
                )
            } else {
                VStack(spacing: SGSpacing.xSmall) {
                    ForEach(viewModel.splitDNSDomains) { domain in
                        domainRow(domain)
                    }
                }
            }

            SplitDNSAddField(
                placeholder: L10n.tr("splitDNS.domains.placeholder", defaultValue: "Add domain, e.g. home.lan"),
                text: $viewModel.newSplitDNSDomain,
                errorText: viewModel.splitDNSInputError,
                onTextChange: { viewModel.splitDNSInputError = nil },
                onAdd: { viewModel.addSplitDNSDomain() }
            )

            Text(
                L10n.tr(
                    "splitDNS.domains.help",
                    defaultValue: "Subdomains are included automatically. Paste several domains separated by commas."
                )
            )
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textTertiary)
        }
    }

    private func domainRow(_ domain: SplitDNSConfiguration.Domain) -> some View {
        let includesApex = !viewModel.isApexExcluded(for: domain.name)
        return SplitDNSNameRow(
            name: domain.name,
            matchDescription: includesApex
                ? L10n.tr("splitDNS.domains.rowWide", defaultValue: "\(domain.name) and *.\(domain.name)")
                : L10n.tr("splitDNS.domains.rowSubdomainsOnly", defaultValue: "*.\(domain.name) only"),
            scope: SplitDNSScopeMenu(
                isWide: includesApex,
                wideTitle: L10n.tr("splitDNS.scope.domainAndSubdomains", defaultValue: "Domain and subdomains"),
                narrowTitle: L10n.tr("splitDNS.scope.subdomainsOnly", defaultValue: "Subdomains only"),
                wideLabel: L10n.tr("splitDNS.scope.plusSubdomains", defaultValue: "+ Subdomains"),
                narrowLabel: L10n.tr("splitDNS.scope.subdomainsOnly", defaultValue: "Subdomains only"),
                accessibilityName: domain.name
            ) { wide in
                withAnimation(.snappy(duration: 0.2)) {
                    viewModel.setSplitDNSDomainIncludesApex(wide, for: domain.name)
                }
            },
            onRemove: {
                withAnimation(.snappy(duration: 0.2)) {
                    viewModel.removeSplitDNSDomain(named: domain.name)
                }
            }
        )
    }
}
