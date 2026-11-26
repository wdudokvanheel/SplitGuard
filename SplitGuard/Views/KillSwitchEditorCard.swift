import SplitGuardCore
import SwiftUI

struct KillSwitchEditorCard: View {
    @Bindable var viewModel: TunnelEditorViewModel

    private var isEligible: Bool {
        viewModel.routesAllIPv4Traffic
    }

    private var effectiveEnabled: Bool {
        isEligible && viewModel.isKillSwitchEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(
                title: L10n.tr("killSwitch.title", defaultValue: "Kill Switch"),
                trailingText: effectiveEnabled
                    ? L10n.tr("common.on", defaultValue: "On")
                    : L10n.tr("common.off", defaultValue: "Off")
            )

            VStack(alignment: .leading, spacing: SGSpacing.small) {
                BrutalistFormToggleRow(
                    title: L10n.tr("killSwitch.toggleTitle", defaultValue: "Kill switch"),
                    subtitle: L10n.tr(
                        "killSwitch.toggleSubtitle",
                        defaultValue: "Block all traffic outside the tunnel while connected"
                    ),
                    isOn: Binding(
                        get: { effectiveEnabled },
                        set: { newValue in
                            guard isEligible else { return }
                            viewModel.isKillSwitchEnabled = newValue
                        }
                    ),
                    activeTint: SGColor.popRed,
                    isInteractive: isEligible
                )

                if !isEligible {
                    noteBox(
                        L10n.tr(
                            "killSwitch.ineligibleNote",
                            defaultValue: """
                            Available only for tunnels that route all IPv4 traffic (0.0.0.0/0). \
                            With split routing, blocking outside traffic would drop everything not in Allowed IPs.
                            """
                        )
                    )
                }

                if effectiveEnabled {
                    Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                    BrutalistFormToggleRow(
                        title: L10n.tr("killSwitch.allowLocalNetwork", defaultValue: "Allow local network"),
                        subtitle: L10n.tr(
                            "killSwitch.allowLocalNetwork.subtitle",
                            defaultValue: "AirPlay, printers, AirDrop"
                        ),
                        isOn: $viewModel.allowLocalNetworkWithKillSwitch,
                        activeTint: SGColor.popYellow
                    )

                    if !viewModel.routesAllIPv6Traffic {
                        noteBox(
                            L10n.tr(
                                "killSwitch.ipv6Note",
                                defaultValue: """
                                This tunnel does not route all IPv6 traffic (::/0). \
                                IPv6 traffic will be blocked while the kill switch is on.
                                """
                            )
                        )
                    }

                    if !viewModel.isOnDemandConfigured {
                        noteBox(
                            L10n.tr(
                                "killSwitch.onDemandNote",
                                defaultValue: """
                                Protection ends when the tunnel is turned off. \
                                Turn on On-Demand to keep it connected.
                                """
                            )
                        )
                    }

                    if viewModel.splitDNSMode == .onlyDomains {
                        noteBox(
                            L10n.tr(
                                "killSwitch.splitDNSNote",
                                defaultValue: """
                                Other names still use the network's DNS server, but the queries now travel through the tunnel. \
                                A DNS server on the local network is only reachable with Allow local network on.
                                """
                            )
                        )
                    } else if viewModel.currentDNSServers.isEmpty {
                        noteBox(
                            L10n.tr(
                                "killSwitch.noDNSNote",
                                defaultValue: """
                                This tunnel has no DNS server configured. Queries travel through the tunnel; \
                                a DNS server on the local network is only reachable with Allow local network on.
                                """
                            )
                        )
                    }

                    if !viewModel.isHealthAlertsEnabled {
                        healthAlertOfferBox
                    }
                }
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private var healthAlertOfferBox: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
            HStack(alignment: .top, spacing: SGSpacing.xSmall) {
                Image(systemName: "bell.badge.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SGColor.textPrimary)
                    .padding(.top, 2)
                Text(
                    L10n.tr(
                        "killSwitch.healthAlertOffer",
                        defaultValue: "Turn on health alerts to be notified if the server becomes unreachable while traffic is blocked."
                    )
                )
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.textPrimary)
            }

            Button {
                Task {
                    await viewModel.setHealthAlertsEnabled(true)
                }
            } label: {
                Text(L10n.tr("killSwitch.turnOnHealthAlerts", defaultValue: "Turn on health alerts").uppercased())
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
                    shadowOffset: SGShadow.small
                )
            )
        }
        .padding(SGSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SGColor.surfaceElevated)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
    }

    private func noteBox(_ message: String) -> some View {
        HStack(alignment: .top, spacing: SGSpacing.xSmall) {
            Image(systemName: "info.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(SGColor.textSecondary)
                .padding(.top, 2)
            Text(message)
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textSecondary)
        }
        .padding(SGSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SGColor.surfaceElevated)
        .overlay(Rectangle().strokeBorder(SGColor.borderSubtle, lineWidth: 1))
    }
}
