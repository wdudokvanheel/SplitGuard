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

        EditorCard(title: "Check routing") {
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
        return count == 0 ? "NONE" : "\(count)"
    }

    var body: some View {
        EditorCard(
            title: "DNS Servers",
            trailingText: serverCountText,
            trailingFill: viewModel.currentDNSServers.isEmpty ? SGColor.surfaceElevated : SGColor.popGreen,
            trailingForeground: viewModel.currentDNSServers.isEmpty ? SGColor.textPrimary : SGColor.inkOnPop
        ) {
            EditorTextRow(
                label: "Server addresses",
                placeholder: viewModel.shouldStronglyRecommendDNS
                    ? String(
                        localized: "tunnel.editor.placeholder.stronglyRecommended",
                        defaultValue: "Strongly recommended"
                    )
                    : String(localized: "tunnel.editor.placeholder.optional", defaultValue: "Optional"),
                text: Binding(get: { viewModel.dns }, set: { viewModel.updateDNS($0) }),
                hasError: viewModel.interfaceErrorFields.contains(.dns),
                isMonospaced: true,
                keyboardType: .numbersAndPunctuation
            )

            Text("The VPN's DNS servers, separated by commas. Lookups routed through the VPN use these.")
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
            title: "Split DNS",
            trailingText: viewModel.splitDNSMode == .onlyDomains ? "SPLIT" : "ALL",
            trailingFill: viewModel.splitDNSMode == .onlyDomains ? SGColor.popBlue : SGColor.popPurple
        ) {
            Text("WHICH LOOKUPS USE THE VPN'S DNS?")
                .font(SGTypography.metricLabel)
                .tracking(0.8)
                .foregroundStyle(SGColor.textSecondary)

            VStack(spacing: 0) {
                modeOption(
                    .allDomains,
                    title: "All domains",
                    subtitle: "Every lookup uses the VPN's DNS, like the official WireGuard app.",
                    systemImage: "globe",
                    accent: SGColor.popPurple
                )
                Rectangle().fill(SGColor.borderInk).frame(height: SGBorder.thin)
                modeOption(
                    .onlyDomains,
                    title: "Only selected domains",
                    subtitle: "Only the domains you add use the VPN's DNS. Everything else uses your network's normal DNS.",
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
            title: "VPN DNS Domains",
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
                    message: "Add the domains of the services you reach through this VPN, like home.lan or corp.example.com."
                )
            } else {
                VStack(spacing: SGSpacing.xSmall) {
                    ForEach(viewModel.splitDNSDomains) { domain in
                        domainRow(domain)
                    }
                }
            }

            SplitDNSAddField(
                placeholder: "Add domain, e.g. home.lan",
                text: $viewModel.newSplitDNSDomain,
                errorText: viewModel.splitDNSInputError,
                onTextChange: { viewModel.splitDNSInputError = nil },
                onAdd: { viewModel.addSplitDNSDomain() }
            )

            Text("Subdomains are included automatically. Paste several domains separated by commas.")
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textTertiary)
        }
    }

    private func domainRow(_ domain: SplitDNSConfiguration.Domain) -> some View {
        let includesApex = !viewModel.isApexExcluded(for: domain.name)
        return SplitDNSNameRow(
            name: domain.name,
            matchDescription: includesApex
                ? "\(domain.name) and *.\(domain.name)"
                : "*.\(domain.name) only",
            scope: SplitDNSScopeMenu(
                isWide: includesApex,
                wideTitle: "Domain and subdomains",
                narrowTitle: "Subdomains only",
                wideLabel: "+ Subdomains",
                narrowLabel: "Subdomains only",
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
