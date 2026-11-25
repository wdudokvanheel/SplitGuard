import SplitGuardCore
import SwiftUI

struct TunnelDetailHeroCard: View {
    let tunnelName: String
    let endpoint: String?
    let displayState: TunnelDisplayState
    let isFavorite: Bool
    let rxText: String
    let txText: String
    let handshakeText: String
    let onToggle: (Bool) -> Void
    let onToggleFavorite: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: SGSpacing.small) {
                HStack(alignment: .top, spacing: SGSpacing.small) {
                    VStack(alignment: .leading, spacing: SGSpacing.xxSmall) {
                        HStack(spacing: SGSpacing.xSmall) {
                            SGStatusBadge(
                                title: displayState.statusText,
                                color: SGColor.pureWhite,
                                isAnimated: displayState.status.isTransitioning,
                                isInactive: false
                            )

                            if let health = displayState.secondaryHealthBadgeState {
                                SGStatusBadge(
                                    title: health.shortLabel,
                                    color: health.badgeColor,
                                    isAnimated: health.isAnimated,
                                    isInactive: health.isNeutral
                                )
                            }
                        }

                        Text(tunnelName.uppercased())
                            .font(SGTypography.displayHero)
                            .tracking(0.8)
                            .foregroundStyle(SGColor.inkOnPop)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)

                        if let endpoint {
                            Text(endpoint)
                                .font(SGTypography.monoValue.weight(.semibold))
                                .foregroundStyle(SGColor.inkOnPop.opacity(0.82))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: SGSpacing.xSmall)

                    VStack(alignment: .trailing, spacing: SGSpacing.xSmall) {
                        BrutalistToggle(
                            isOn: displayState.isSwitchOn,
                            activeTint: displayState.switchTint,
                            isInteractive: displayState.isSwitchInteractive,
                            accessibilityLabelText: "Toggle \(tunnelName)",
                            shadowColor: SGColor.shadowInk,
                            onToggle: onToggle
                        )

                        Button(action: onToggleFavorite) {
                            HStack(spacing: 4) {
                                Image(systemName: isFavorite ? "star.fill" : "star")
                                    .font(.caption.weight(.bold))
                                Text(isFavorite ? "PINNED" : "PIN")
                                    .font(SGTypography.metricLabel)
                            }
                            .foregroundStyle(SGColor.inkOnPop)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(isFavorite ? SGColor.popYellow : SGColor.pureWhite)
                            .overlay(Rectangle().strokeBorder(SGColor.pureBlack, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(SGSpacing.medium)
            .background {
                ZStack {
                    displayState.heroBannerColor
                    BrutalistGrainOverlay(opacity: 0.2)
                }
            }

            if displayState.status == .active {
                if let health = displayState.activeHealthState, let detail = health.detailMessage {
                    Rectangle().fill(SGColor.borderInk).frame(height: SGBorder.regular)
                    TunnelHealthBannerStrip(health: health, message: detail)
                }
                Rectangle().fill(SGColor.borderInk).frame(height: SGBorder.regular)
                liveStatsStrip
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.thick, shadowOffset: SGShadow.medium)
    }

    @ViewBuilder
    private var liveStatsStrip: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 0) {
                statCell(title: "RECEIVED", value: rxText, accent: SGColor.popPurple)
                Rectangle().fill(SGColor.borderInk).frame(height: SGBorder.thin)
                statCell(title: "SENT", value: txText, accent: SGColor.popGreen)
                Rectangle().fill(SGColor.borderInk).frame(height: SGBorder.thin)
                statCell(title: "HANDSHAKE", value: handshakeText, accent: SGColor.popYellow)
            }
            .background(SGColor.surfaceCard)
        } else {
            HStack(spacing: 0) {
                statCell(title: "RECEIVED", value: rxText, accent: SGColor.popPurple)
                Rectangle().fill(SGColor.borderInk).frame(width: SGBorder.regular)
                statCell(title: "SENT", value: txText, accent: SGColor.popGreen)
                Rectangle().fill(SGColor.borderInk).frame(width: SGBorder.regular)
                statCell(title: "HANDSHAKE", value: handshakeText, accent: SGColor.popYellow)
            }
            .background(SGColor.surfaceCard)
        }
    }

    private func statCell(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                    .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
                Text(title)
                    .font(SGTypography.metricLabel)
                    .foregroundStyle(SGColor.textSecondary)
            }
            Text(value)
                .font(SGTypography.metricValue)
                .foregroundStyle(SGColor.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, SGSpacing.small)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TunnelDetailOnDemandCard: View {
    let interfaceSummary: String
    let ssidSummary: String?
    let selectedSSIDs: [String]

    var body: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: String(localized: "tunnel.section.onDemand", defaultValue: "On-Demand Activation"))
            VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
                HStack {
                    Text(String(localized: "tunnel.onDemand.label", defaultValue: "On-demand").uppercased())
                        .font(SGTypography.metricLabel)
                        .foregroundStyle(SGColor.textSecondary)
                    Spacer()
                    Text(interfaceSummary)
                        .font(SGTypography.subheadline)
                        .foregroundStyle(SGColor.textPrimary)
                }

                if let ssidSummary {
                    Rectangle().fill(SGColor.borderSubtle).frame(height: 1)
                    HStack {
                        Text(String(localized: "tunnel.onDemand.ssids", defaultValue: "SSIDs").uppercased())
                            .font(SGTypography.metricLabel)
                            .foregroundStyle(SGColor.textSecondary)
                        Spacer()
                        Text(ssidSummary)
                            .font(SGTypography.subheadline)
                            .foregroundStyle(SGColor.textPrimary)
                    }
                }

                ForEach(selectedSSIDs, id: \.self) { ssid in
                    HStack(spacing: SGSpacing.xSmall) {
                        Image(systemName: "wifi")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(SGColor.inkOnPop)
                            .padding(5)
                            .background(SGColor.popPurple)
                            .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
                        Text(ssid)
                            .font(SGTypography.monoCompact)
                            .foregroundStyle(SGColor.textPrimary)
                    }
                }
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }
}

struct TunnelDetailKillSwitchCard: View {
    let isEnabled: Bool
    let allowLocalNetwork: Bool

    var body: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(
                title: "Kill Switch",
                trailingText: isEnabled ? "ON" : "OFF"
            )
            VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
                HStack {
                    Text("STATUS")
                        .font(SGTypography.metricLabel)
                        .foregroundStyle(SGColor.textSecondary)
                    Spacer()
                    Text(isEnabled ? "ENABLED" : "OFF")
                        .font(SGTypography.badge)
                        .foregroundStyle(isEnabled ? SGColor.pureWhite : SGColor.textPrimary)
                        .padding(.horizontal, SGSpacing.xSmall)
                        .padding(.vertical, 3)
                        .background(isEnabled ? SGColor.popRed : SGColor.surfaceElevated)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))
                }

                if isEnabled {
                    Rectangle().fill(SGColor.borderSubtle).frame(height: 1)
                    HStack {
                        Text("LOCAL NETWORK")
                            .font(SGTypography.metricLabel)
                            .foregroundStyle(SGColor.textSecondary)
                        Spacer()
                        Text(allowLocalNetwork ? "Allowed (AirPlay, AirDrop, printers)" : "Blocked")
                            .font(SGTypography.subheadline)
                            .foregroundStyle(SGColor.textPrimary)
                    }
                }
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }
}

struct TunnelDetailHealthAlertsCard: View {
    let healthAlerts: TunnelLocalSettings.HealthAlerts

    var body: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(
                title: "Health Alerts",
                trailingText: healthAlerts.isEnabled ? "ON" : "OFF",
                trailingFill: healthAlerts.isEnabled ? SGColor.popGreen : SGColor.surfaceElevated,
                trailingForeground: healthAlerts.isEnabled ? SGColor.inkOnPop : SGColor.textPrimary
            )
            VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
                HStack {
                    Text("STATUS")
                        .font(SGTypography.metricLabel)
                        .foregroundStyle(SGColor.textSecondary)
                    Spacer()
                    Text(healthAlerts.isEnabled ? "ENABLED" : "OFF")
                        .font(SGTypography.badge)
                        .foregroundStyle(healthAlerts.isEnabled ? SGColor.inkOnPop : SGColor.textPrimary)
                        .padding(.horizontal, SGSpacing.xSmall)
                        .padding(.vertical, 3)
                        .background(healthAlerts.isEnabled ? SGColor.popGreen : SGColor.surfaceElevated)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))
                }

                if healthAlerts.isEnabled {
                    Rectangle().fill(SGColor.borderSubtle).frame(height: 1)
                    HStack {
                        Text("ALERT AFTER")
                            .font(SGTypography.metricLabel)
                            .foregroundStyle(SGColor.textSecondary)
                        Spacer()
                        Text(HealthAlertsEditorCard.longDelayLabel(healthAlerts.delaySeconds))
                            .font(SGTypography.subheadline)
                            .foregroundStyle(SGColor.textPrimary)
                    }
                }
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }
}
