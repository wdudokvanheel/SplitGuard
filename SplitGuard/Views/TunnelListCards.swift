import SwiftUI

struct ActiveTunnelCardView: View {
    let tunnel: TunnelContainer
    let displayState: TunnelDisplayState
    let onOpenDetail: () -> Void
    let onDisconnect: () -> Void

    private var endpoint: String? {
        let endpoints = tunnel.tunnelConfiguration?.peers.compactMap(\.endpoint) ?? []
        if endpoints.count == 1 {
            return endpoints[0].stringRepresentation
        }
        return endpoints.count > 1 ? "\(endpoints.count) peers" : nil
    }

    var body: some View {
        HStack(spacing: SGSpacing.small) {
            Button(action: onOpenDetail) {
                HStack(spacing: SGSpacing.small) {
                    ZStack {
                        RoundedRectangle(cornerRadius: SGRadius.medium, style: .continuous)
                            .fill(displayState.statusColor.opacity(0.16))
                            .frame(width: 44, height: 44)
                        Image(systemName: displayState.status.symbolName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(displayState.statusColor)
                    }

                    VStack(alignment: .leading, spacing: SGSpacing.xxSmall) {
                        Text(tunnel.name)
                            .font(SGTypography.cardTitle)
                            .foregroundStyle(SGColor.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: SGSpacing.xSmall) {
                            SGStatusBadge(
                                title: displayState.statusText,
                                color: displayState.statusColor,
                                isAnimated: displayState.status.isTransitioning
                            )
                            if let endpoint {
                                Text(endpoint)
                                    .font(SGTypography.monoCompact)
                                    .foregroundStyle(SGColor.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDisconnect) {
                Text("Disconnect")
                    .font(SGTypography.badge)
            }
            .buttonStyle(.bordered)
            .tint(SGColor.statusError)
            .disabled(displayState.status == .deactivating)
        }
        .padding(SGSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: SGRadius.large, style: .continuous)
                .fill(SGColor.surfaceCard)
                .overlay(
                    RoundedRectangle(cornerRadius: SGRadius.large, style: .continuous)
                        .strokeBorder(displayState.statusColor.opacity(0.32), lineWidth: 1)
                )
        )
    }
}

struct ActivationErrorCardView: View {
    let banner: ActivationErrorBanner
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: SGSpacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SGColor.statusError)
                .font(.title3)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: SGSpacing.xxSmall) {
                Text("\(banner.tunnelName): \(banner.title)")
                    .font(SGTypography.sectionTitle)
                    .foregroundStyle(SGColor.textPrimary)
                Text(banner.message)
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SGColor.textSecondary)
                    .padding(SGSpacing.xxSmall)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(SGSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: SGRadius.large, style: .continuous)
                .fill(SGColor.statusError.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: SGRadius.large, style: .continuous)
                        .strokeBorder(SGColor.statusError.opacity(0.3), lineWidth: 1)
                )
        )
    }
}
