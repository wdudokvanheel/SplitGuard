import SwiftUI

struct TunnelRowView: View {
    let tunnel: Tunnel
    let displayState: TunnelDisplayState
    var rowIndex: Int = 0
    var isFavorite: Bool = false
    var isSelecting: Bool = false
    var isSelected: Bool = false
    let onSelect: () -> Void
    let onToggle: (Bool) -> Void
    var onToggleFavorite: (() -> Void)?
    var onDelete: (() -> Void)?

    private var accentColor: Color {
        SGColor.rowAccent(at: rowIndex)
    }

    private var endpointText: String? {
        let endpoints = tunnel.profile.peers.compactMap(\.endpoint)
        if endpoints.count == 1 {
            return endpoints[0].description
        }
        if endpoints.count > 1 {
            return L10n.tr("tunnel.peersCount", defaultValue: "\(endpoints.count) peers")
        }
        return nil
    }

    private var tags: [String] {
        var result: [String] = []
        if displayState.status != .inactive {
            result.append(displayState.statusText)
            if let health = displayState.secondaryHealthBadgeState {
                result.append(health.shortLabel)
            }
        }
        if tunnel.splitDNS.mode == .onlyDomains {
            let count = tunnel.splitDNS.normalizedDomainNames.count
            result.append(
                count == 1
                    ? L10n.tr("tunnel.tag.splitDNS", defaultValue: "Split DNS")
                    : L10n.tr("tunnel.tag.splitDNSCount", defaultValue: "Split DNS (\(count))")
            )
        }
        if tunnel.options.killSwitch.isEnabled {
            result.append(L10n.tr("tunnel.tag.killSwitch", defaultValue: "Kill switch"))
        }
        if displayState.hasOnDemandRules {
            result.append(
                displayState.isOnDemandEnabled
                    ? L10n.tr("tunnel.tag.onDemand", defaultValue: "On-Demand")
                    : L10n.tr("tunnel.tag.onDemandOff", defaultValue: "On-Demand Off")
            )
        }
        if isFavorite {
            result.append(L10n.tr("tunnel.tag.favorite", defaultValue: "Favorite"))
        }
        if result.isEmpty {
            result.append(L10n.tr("tunnel.tag.allDomains", defaultValue: "All domains"))
        }
        return result
    }

    private var titleColor: Color {
        isSelected ? SGColor.inkOnPop : SGColor.textPrimary
    }

    private var secondaryColor: Color {
        isSelected ? SGColor.inkOnPop.opacity(0.78) : SGColor.textSecondary
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(
                    displayState.status == .active
                        ? displayState.heroBannerColor
                        : accentColor
                )
                .frame(width: 8)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(isSelected ? SGColor.pureBlack : SGColor.borderInk)
                        .frame(width: SGBorder.thin)
                }

            HStack(spacing: SGSpacing.small) {
                Button(action: onSelect) {
                    HStack(spacing: SGSpacing.small) {
                        if isSelecting {
                            selectionBox
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: SGSpacing.xSmall) {
                                Text(tunnel.name.uppercased())
                                    .font(SGTypography.displayTitle)
                                    .tracking(0.6)
                                    .foregroundStyle(titleColor)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)

                                if isFavorite && !isSelecting {
                                    Image(systemName: "star.fill")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(SGColor.inkOnPop)
                                        .padding(4)
                                        .background(SGColor.popYellow)
                                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
                                }
                            }

                            if let endpointText {
                                Text(endpointText)
                                    .font(SGTypography.monoCompact)
                                    .foregroundStyle(secondaryColor)
                                    .lineLimit(1)
                            }

                            BrutalistTagStrip(
                                tags: tags,
                                textColor: titleColor,
                                separatorColor: isSelected ? SGColor.inkOnPop : SGColor.borderInk
                            )
                            .padding(.top, 2)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, SGSpacing.small)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !isSelecting {
                    BrutalistToggle(
                        isOn: displayState.isSwitchOn,
                        activeTint: displayState.switchTint,
                        isInteractive: displayState.isSwitchInteractive,
                        accessibilityLabelText: L10n.tr(
                            "tunnel.action.toggleAccessibility",
                            defaultValue: "Toggle \(tunnel.name)"
                        ),
                        onToggle: onToggle
                    )
                }
            }
            .padding(.horizontal, SGSpacing.small)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.sharp, style: .continuous))
        .brutalistCard(
            fill: isSelected ? SGColor.popYellow : SGColor.surfaceCard,
            borderWidth: SGBorder.regular,
            shadowOffset: SGShadow.small,
            cornerRadius: SGRadius.sharp,
            showGrain: isSelected
        )
        .contextMenu {
            if !isSelecting {
                if let onToggleFavorite {
                    Button(action: onToggleFavorite) {
                        Label(
                            isFavorite
                                ? L10n.tr("tunnel.action.unpinFavorite", defaultValue: "Remove favorite")
                                : L10n.tr("tunnel.action.pinFavorite", defaultValue: "Pin as favorite"),
                            systemImage: isFavorite ? "star.slash" : "star.fill"
                        )
                    }
                }
                Button(action: onSelect) {
                    Label(
                        L10n.tr("tunnel.action.inspect", defaultValue: "Inspect tunnel"),
                        systemImage: "info.circle"
                    )
                }
                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Label(L10n.tr("action.delete", defaultValue: "Delete"), systemImage: "trash")
                    }
                }
            }
        }
    }

    private var selectionBox: some View {
        ZStack {
            Rectangle()
                .fill(isSelected ? SGColor.popPink : SGColor.surfaceCard)
                .frame(width: 26, height: 26)
                .overlay(
                    Rectangle().strokeBorder(
                        isSelected ? SGColor.pureBlack : SGColor.borderInk,
                        lineWidth: SGBorder.regular
                    )
                )
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.black))
                    .foregroundStyle(SGColor.pureWhite)
            }
        }
    }
}
