import SwiftUI

struct FeaturedTunnelHeroCardView: View {
    let tunnel: TunnelContainer
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

    private var endpoint: String? {
        let endpoints = tunnel.tunnelConfiguration?.peers.compactMap(\.endpoint) ?? []
        if endpoints.count == 1 {
            return endpoints[0].stringRepresentation
        }
        return endpoints.count > 1 ? "\(endpoints.count) peers" : nil
    }

    private var roleLabel: String {
        if displayState.status != .inactive {
            return "ACTIVE CONNECTION"
        }
        if isFavorite {
            return "FAVOURITE TUNNEL"
        }
        return "PRIMARY TUNNEL"
    }

    private var featureTags: [String] {
        var tags: [String] = []
        let splitDNS = tunnel.splitDNSConfiguration
        if splitDNS.mode == .onlyDomains {
            let count = splitDNS.normalizedDomainNames.count
            tags.append(count == 1 ? "SPLIT DNS: \(splitDNS.normalizedDomainNames[0])" : "SPLIT DNS (\(count))")
        } else {
            tags.append("ALL DOMAINS")
        }
        if displayState.hasOnDemandRules {
            tags.append(displayState.isOnDemandEnabled ? "ON-DEMAND ON" : "ON-DEMAND OFF")
        }
        return tags
    }

    private var primaryActionTitle: String {
        switch displayState.status {
        case .active:
            return "DISCONNECT"
        case .activating, .reasserting, .restarting, .waiting:
            return "CONNECTING…"
        case .deactivating:
            return "DISCONNECTING…"
        case .inactive:
            return displayState.isOnDemandEnabled ? "DISABLE ON-DEMAND" : "CONNECT NOW"
        }
    }

    private var primaryActionAccent: Color {
        displayState.isSwitchOn ? SGColor.popRed : SGColor.popGreen
    }

    var body: some View {
        VStack(spacing: 0) {
            heroTopBand
            metricsStrip
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.thick, shadowOffset: SGShadow.large)
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: displayState.status)
    }

    private var heroTopBand: some View {
        VStack(alignment: .leading, spacing: SGSpacing.medium) {
            HStack(spacing: SGSpacing.xSmall) {
                Text(roleLabel)
                    .font(SGTypography.metricLabel)
                    .tracking(1.0)
                    .foregroundStyle(SGColor.invertedBarText)
                    .padding(.horizontal, SGSpacing.xSmall)
                    .padding(.vertical, 4)
                    .background(SGColor.invertedBar)

                SGStatusBadge(
                    title: displayState.statusText,
                    color: SGColor.pureWhite,
                    isAnimated: displayState.status.isTransitioning,
                    isInactive: false
                )

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
                .accessibilityLabel(isFavorite ? "Remove favourite" : "Pin as favourite")
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
            .accessibilityHint("Opens tunnel details")

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
                fullWidth: true
            )
        )
        .disabled(!displayState.isSwitchInteractive)
        .accessibilityLabel("\(primaryActionTitle) \(tunnel.name)")
    }

    @ViewBuilder
    private var metricsStrip: some View {
        let isActive = displayState.status == .active
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 0) {
                metricCell(label: "RECEIVED", value: isActive ? rxText : "—", accent: SGColor.popBlue)
                Rectangle().fill(SGColor.borderInk).frame(height: SGBorder.thin)
                metricCell(label: "SENT", value: isActive ? txText : "—", accent: SGColor.popGreen)
                Rectangle().fill(SGColor.borderInk).frame(height: SGBorder.thin)
                metricCell(label: "HANDSHAKE", value: isActive ? handshakeText : "Idle", accent: SGColor.popYellow)
            }
            .background(SGColor.surfaceCard)
        } else {
            HStack(spacing: 0) {
                metricCell(label: "RECEIVED", value: isActive ? rxText : "—", accent: SGColor.popBlue)
                Rectangle().fill(SGColor.borderInk).frame(width: SGBorder.regular)
                metricCell(label: "SENT", value: isActive ? txText : "—", accent: SGColor.popGreen)
                Rectangle().fill(SGColor.borderInk).frame(width: SGBorder.regular)
                metricCell(label: "HANDSHAKE", value: isActive ? handshakeText : "Idle", accent: SGColor.popYellow)
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
            .accessibilityLabel("Dismiss error")
        }
        .padding(SGSpacing.medium)
        .brutalistCard(fill: SGColor.popRed, borderWidth: SGBorder.regular, shadowOffset: SGShadow.medium, showGrain: true)
    }
}
