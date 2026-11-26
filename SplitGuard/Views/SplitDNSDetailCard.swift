import SplitGuardCore
import SwiftUI
import WireGuardEngine

struct SplitDNSDetailCard: View {
    let splitDNS: SplitDNSConfiguration
    let dnsServers: [IPAddress]
    let warnings: [SplitDNSConfiguration.ValidationWarning]
    let isTunnelActive: Bool

    private var modeLabel: String {
        switch splitDNS.mode {
        case .allDomains:
            return L10n.tr("splitDNS.mode.allDomains", defaultValue: "All domains").uppercased()
        case .onlyDomains:
            return L10n.tr("splitDNS.mode.onlyDomains.short", defaultValue: "Only these domains").uppercased()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(
                title: L10n.tr("splitDNS.title", defaultValue: "Split DNS"),
                trailingText: splitDNS.mode == .onlyDomains
                    ? L10n.tr("splitDNS.badge.split", defaultValue: "Split")
                    : L10n.tr("splitDNS.badge.all", defaultValue: "All")
            )

            VStack(alignment: .leading, spacing: SGSpacing.small) {
                HStack {
                    Text(L10n.tr("splitDNS.modeLabel", defaultValue: "Mode").uppercased())
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
                    Text(L10n.tr("splitDNS.domains.detailHeader", defaultValue: "Use VPN DNS for").uppercased())
                        .font(SGTypography.metricLabel)
                        .tracking(0.8)
                        .foregroundStyle(SGColor.textSecondary)

                    if splitDNS.domains.isEmpty {
                        Text(L10n.tr("splitDNS.domains.empty", defaultValue: "No domains configured"))
                            .font(SGTypography.subheadline)
                            .foregroundStyle(SGColor.textTertiary)
                    } else {
                        VStack(spacing: SGSpacing.xSmall) {
                            ForEach(splitDNS.domains) { domain in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(domain.name)
                                        .font(SGTypography.monoValue.weight(.semibold))
                                        .foregroundStyle(SGColor.textPrimary)
                                    Text(
                                        L10n.tr(
                                            "splitDNS.domains.matchWide",
                                            defaultValue: "Matches \(domain.name) and *.\(domain.name)"
                                        )
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
                }

                if !splitDNS.exclusions.isEmpty {
                    Text(L10n.tr("splitDNS.exceptions.detailHeader", defaultValue: "Keep on normal DNS").uppercased())
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
                                        ? L10n.tr(
                                            "splitDNS.domains.matchWide",
                                            defaultValue: "Matches \(exclusion.name) and *.\(exclusion.name)"
                                        )
                                        : L10n.tr(
                                            "splitDNS.domains.matchExact",
                                            defaultValue: "Matches \(exclusion.name) only"
                                        )
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
