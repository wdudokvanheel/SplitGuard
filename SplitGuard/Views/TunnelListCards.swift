import SwiftUI

struct FeaturedTunnelHeroCardView: View {
    let tunnel: Tunnel
    let displayState: TunnelDisplayState
    let isFavorite: Bool
    let rxText: String
    let txText: String
    let handshakeText: String
    let onOpenDetail: () -> Void
    let onToggleConnection: (Bool) -> Void
    let onToggleFavorite: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            heroTopBand
            if let health = displayState.activeHealthState, let detail = health.detailMessage {
                TunnelHealthBannerStrip(health: health, message: detail)
                Rectangle()
                    .fill(SGColor.borderInk)
                    .frame(height: SGBorder.regular)
            }
            metricsStrip
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.thick, shadowOffset: SGShadow.large)
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: displayState.status)
    }

    private var heroTopBand: some View {
        VStack(alignment: .leading, spacing: SGSpacing.medium) {
            HStack(spacing: SGSpacing.xSmall) {
                if let roleLabel {
                    Text(roleLabel)
                        .font(SGTypography.metricLabel)
                        .tracking(1.0)
                        .foregroundStyle(SGColor.invertedBarText)
                        .padding(.horizontal, SGSpacing.xSmall)
                        .padding(.vertical, 4)
                        .background(SGColor.invertedBar)
                }

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

                Spacer(minLength: SGSpacing.xxSmall)

                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(SGColor.inkOnPop)
                        .frame(width: 34, height: 34)
                        .background(isFavorite ? SGColor.popYellow : SGColor.pureWhite)
                        .overlay(Rectangle().strokeBorder(SGColor.pureBlack, lineWidth: SGBorder.thin))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isFavorite
                        ? L10n.tr("tunnel.action.unpinFavorite", defaultValue: "Remove favorite")
                        : L10n.tr("tunnel.action.pinFavorite", defaultValue: "Pin as favorite")
                )
            }

            Button(action: onOpenDetail) {
                HStack(alignment: .top, spacing: SGSpacing.small) {
                    VStack(alignment: .leading, spacing: SGSpacing.xxSmall) {
                        Text(tunnel.name.uppercased())
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

                        BrutalistTagStrip(
                            tags: featureTags,
                            textColor: SGColor.inkOnPop,
                            separatorColor: SGColor.inkOnPop
                        )
                        .padding(.top, 2)
                    }

                    Spacer(minLength: SGSpacing.xSmall)

                    Image(systemName: "arrow.up.right")
                        .font(.headline.weight(.black))
                        .foregroundStyle(SGColor.inkOnPop)
                        .frame(width: 34, height: 34)
                        .background(SGColor.creme)
                        .overlay(Rectangle().strokeBorder(SGColor.pureBlack, lineWidth: SGBorder.thin))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.tr("tunnel.action.opensDetailsHint", defaultValue: "Opens tunnel details"))

            primaryActionButton
        }
        .padding(SGSpacing.medium)
        .background {
            ZStack {
                displayState.heroBannerColor
                BrutalistGrainOverlay(opacity: 0.2)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SGColor.borderInk)
                .frame(height: SGBorder.regular)
        }
    }

    private var primaryActionButton: some View {
        Button {
            onToggleConnection(!displayState.isSwitchOn)
        } label: {
            HStack(spacing: SGSpacing.xSmall) {
                if displayState.status.isTransitioning {
                    ProgressView()
                        .tint(SGColor.inkOnPop)
                } else {
                    Image(systemName: displayState.isSwitchOn ? "bolt.slash.fill" : "bolt.fill")
                        .font(.headline.weight(.black))
                        .foregroundStyle(primaryActionAccent)
                }
                Text(primaryActionTitle)
                    .font(SGTypography.displayButton)
                    .tracking(1.2)
                    .foregroundStyle(SGColor.inkOnPop)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, SGSpacing.medium)
        }
        .buttonStyle(
            BrutalistButtonStyle(
                fill: SGColor.pureWhite,
                foreground: SGColor.inkOnPop,
                borderWidth: SGBorder.regular,
                shadowOffset: SGShadow.medium,
                shadowColor: SGColor.shadowInk,
                fullWidth: true
            )
        )
        .disabled(!displayState.isSwitchInteractive)
        .accessibilityLabel("\(primaryActionTitle) \(tunnel.name)")
    }

    @ViewBuilder
    private var metricsStrip: some View {
        let isActive = displayState.status == .active
        let receivedLabel = L10n.tr("tunnel.metric.received", defaultValue: "Received").uppercased()
        let sentLabel = L10n.tr("tunnel.metric.sent", defaultValue: "Sent").uppercased()
        let handshakeLabel = L10n.tr("tunnel.metric.handshake", defaultValue: "Handshake").uppercased()
        let idleValue = L10n.tr("tunnel.metric.idle", defaultValue: "Idle")
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 0) {
                metricCell(label: receivedLabel, value: isActive ? rxText : "—", accent: SGColor.popPurple)
                Rectangle().fill(SGColor.borderInk).frame(height: SGBorder.thin)
                metricCell(label: sentLabel, value: isActive ? txText : "—", accent: SGColor.popGreen)
                Rectangle().fill(SGColor.borderInk).frame(height: SGBorder.thin)
                metricCell(label: handshakeLabel, value: isActive ? handshakeText : idleValue, accent: SGColor.popYellow)
            }
            .background(SGColor.surfaceCard)
        } else {
            HStack(spacing: 0) {
                metricCell(label: receivedLabel, value: isActive ? rxText : "—", accent: SGColor.popPurple)
                Rectangle().fill(SGColor.borderInk).frame(width: SGBorder.regular)
                metricCell(label: sentLabel, value: isActive ? txText : "—", accent: SGColor.popGreen)
                Rectangle().fill(SGColor.borderInk).frame(width: SGBorder.regular)
                metricCell(label: handshakeLabel, value: isActive ? handshakeText : idleValue, accent: SGColor.popYellow)
            }
            .background(SGColor.surfaceCard)
        }
    }

    private func metricCell(label: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Rectangle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                    .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
                Text(label)
                    .font(SGTypography.metricLabel)
                    .tracking(0.7)
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

private extension FeaturedTunnelHeroCardView {
    var endpoint: String? {
        let endpoints = tunnel.profile.peers.compactMap(\.endpoint)
        if endpoints.count == 1 {
            return endpoints[0].description
        }
        return endpoints.count > 1
            ? L10n.tr("tunnel.peersCount", defaultValue: "\(endpoints.count) peers")
            : nil
    }

    var roleLabel: String? {
        displayState.status == .inactive
            ? L10n.tr("tunnel.role.primary", defaultValue: "Primary tunnel").uppercased()
            : nil
    }

    var featureTags: [String] {
        var tags: [String] = []
        let splitDNS = tunnel.splitDNS
        if splitDNS.mode == .onlyDomains {
            let count = splitDNS.normalizedDomainNames.count
            if count == 1 {
                tags.append(
                    L10n.tr(
                        "tunnel.tag.splitDNSSingle",
                        defaultValue: "Split DNS: \(splitDNS.normalizedDomainNames[0])"
                    )
                )
            } else {
                tags.append(L10n.tr("tunnel.tag.splitDNSCount", defaultValue: "Split DNS (\(count))"))
            }
        } else {
            tags.append(L10n.tr("tunnel.tag.allDomains", defaultValue: "All domains"))
        }
        if tunnel.options.killSwitch.isEnabled {
            tags.append(L10n.tr("tunnel.tag.killSwitch", defaultValue: "Kill switch"))
        }
        if displayState.hasOnDemandRules {
            tags.append(
                displayState.isOnDemandEnabled
                    ? L10n.tr("tunnel.tag.onDemandOn", defaultValue: "On-Demand On")
                    : L10n.tr("tunnel.tag.onDemandOff", defaultValue: "On-Demand Off")
            )
        }
        return tags
    }

    var primaryActionTitle: String {
        switch displayState.status {
        case .active:
            return L10n.tr("tunnel.action.disconnect", defaultValue: "Disconnect").uppercased()
        case .activating, .reasserting, .restarting, .waiting:
            return L10n.tr("tunnel.action.connecting", defaultValue: "Connecting…").uppercased()
        case .deactivating:
            return L10n.tr("tunnel.action.disconnecting", defaultValue: "Disconnecting…").uppercased()
        case .inactive:
            return displayState.isOnDemandEnabled
                ? L10n.tr("tunnel.action.disableOnDemand", defaultValue: "Disable On-Demand").uppercased()
                : L10n.tr("tunnel.action.connectNow", defaultValue: "Connect now").uppercased()
        }
    }

    var primaryActionAccent: Color {
        displayState.isSwitchOn ? SGColor.popRed : SGColor.popGreen
    }
}

struct ActivationErrorCardView: View {
    let banner: ActivationErrorBanner
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: SGSpacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SGColor.inkOnPop)
                .font(.title3.weight(.black))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: SGSpacing.xxSmall) {
                Text("\(banner.tunnelName.uppercased()): \(banner.title.uppercased())")
                    .font(SGTypography.displayCompact)
                    .tracking(0.6)
                    .foregroundStyle(SGColor.inkOnPop)
                Text(banner.message)
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.inkOnPop.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.black))
                    .foregroundStyle(SGColor.inkOnPop)
                    .frame(width: 28, height: 28)
                    .background(SGColor.pureWhite)
                    .overlay(Rectangle().strokeBorder(SGColor.pureBlack, lineWidth: SGBorder.thin))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("tunnel.error.dismissAccessibility", defaultValue: "Dismiss error"))
        }
        .padding(SGSpacing.medium)
        .brutalistCard(fill: SGColor.popRed, borderWidth: SGBorder.regular, shadowOffset: SGShadow.medium, showGrain: true)
    }
}

struct MultiSelectBottomBarView: View {
    let selectedCount: Int
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(SGColor.borderInk)
                .frame(height: SGBorder.regular)

            HStack(spacing: SGSpacing.small) {
                Text(
                    selectedCount == 0
                        ? L10n.tr("tunnels.list.tapToSelect", defaultValue: "Tap tunnels to select")
                        : L10n.tr("tunnels.list.selectedCount", defaultValue: "\(selectedCount) selected")
                )
                .font(SGTypography.subheadline)
                .foregroundStyle(SGColor.textPrimary)

                Spacer()

                Button(action: onDelete) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash.fill")
                            .font(.caption.weight(.bold))
                        Text(L10n.tr("action.delete", defaultValue: "Delete").uppercased())
                            .font(SGTypography.displayCompact)
                            .tracking(0.8)
                    }
                    .padding(.horizontal, SGSpacing.medium)
                    .padding(.vertical, 8)
                }
                .buttonStyle(
                    BrutalistButtonStyle(
                        fill: SGColor.popRed,
                        foreground: SGColor.pureWhite,
                        borderWidth: SGBorder.regular,
                        shadowOffset: SGShadow.small
                    )
                )
                .disabled(selectedCount == 0)
            }
            .padding(.horizontal, SGSpacing.medium)
            .padding(.vertical, SGSpacing.medium)
        }
        .frame(maxWidth: .infinity)
        .background(SGColor.surfaceCard.ignoresSafeArea(edges: .bottom))
    }
}
