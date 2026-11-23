import SwiftUI

struct TunnelRowView: View {
    let tunnel: TunnelContainer
    let displayState: TunnelDisplayState
    var isSelecting: Bool = false
    var isSelected: Bool = false
    let onSelect: () -> Void
    let onToggle: (Bool) -> Void

    private var endpointText: String? {
        let endpoints = tunnel.tunnelConfiguration?.peers.compactMap(\.endpoint) ?? []
        if endpoints.count == 1 {
            return endpoints[0].stringRepresentation
        }
        if endpoints.count > 1 {
            return "\(endpoints.count) peers"
        }
        return nil
    }

    var body: some View {
        HStack(spacing: SGSpacing.small) {
            Button(action: onSelect) {
                HStack(spacing: SGSpacing.small) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? SGColor.accent : SGColor.textTertiary)
                    } else {
                        statusIndicator
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(tunnel.name)
                            .font(SGTypography.cardTitle)
                            .foregroundStyle(SGColor.textPrimary)
                            .lineLimit(1)

                        subtitleView
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isSelecting {
                Toggle(
                    isOn: Binding(
                        get: { displayState.isSwitchOn },
                        set: { newValue in
                            onToggle(newValue)
                        }
                    )
                ) {
                    EmptyView()
                }
                .labelsHidden()
                .tint(displayState.switchTint)
                .disabled(!displayState.isSwitchInteractive)
                .accessibilityLabel("Toggle \(tunnel.name)")

                Button(action: onSelect) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SGColor.textTertiary)
                        .padding(.leading, 2)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if displayState.status.isTransitioning {
            ProgressView()
                .controlSize(.small)
                .tint(displayState.statusColor)
                .frame(width: 14, height: 14)
        } else {
            Circle()
                .fill(displayState.statusColor)
                .frame(width: 10, height: 10)
                .padding(2)
        }
    }

    private var subtitleView: some View {
        HStack(spacing: SGSpacing.xSmall) {
            if displayState.status != .inactive {
                Text(displayState.statusText)
                    .font(SGTypography.caption.weight(.medium))
                    .foregroundStyle(displayState.statusColor)
            } else if let endpointText {
                Text(endpointText)
                    .font(SGTypography.monoCompact)
                    .foregroundStyle(SGColor.textSecondary)
                    .lineLimit(1)
            } else {
                Text(displayState.statusText)
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.textSecondary)
            }

            if displayState.hasOnDemandRules {
                Text(tr("tunnelListCaptionOnDemand"))
                    .font(SGTypography.metricLabel)
                    .foregroundStyle(displayState.isOnDemandEnabled ? SGColor.accent : SGColor.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill((displayState.isOnDemandEnabled ? SGColor.accent : SGColor.textTertiary).opacity(0.14))
                    )
            }
        }
    }
}
