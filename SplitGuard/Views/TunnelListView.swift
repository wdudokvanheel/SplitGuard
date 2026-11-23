import SwiftUI

struct TunnelListView: View {
    let store: TunnelStore
    let onSelectTunnel: (TunnelContainer) -> Void
    let onImportFiles: () -> Void
    let onScanQRCode: () -> Void
    let onPasteConfig: () -> Void

    @State private var tunnelPendingDelete: TunnelContainer?

    var body: some View {
        Group {
            if store.isLoading {
                ProgressView("Loading tunnels…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SGColor.surfacePrimary)
            } else if store.tunnels.isEmpty {
                emptyStateView
            } else {
                tunnelListContent
            }
        }
        .navigationTitle("SplitGuard")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                addTunnelMenu
            }
        }
        .confirmationDialog(
            "Delete Tunnel",
            isPresented: Binding(
                get: { tunnelPendingDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        tunnelPendingDelete = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let tunnel = tunnelPendingDelete {
                Button(tr("deleteTunnelConfirmationAlertButtonTitle"), role: .destructive) {
                    store.delete(tunnel: tunnel)
                    tunnelPendingDelete = nil
                }
            }
            Button(tr("actionCancel"), role: .cancel) {
                tunnelPendingDelete = nil
            }
        } message: {
            if let tunnel = tunnelPendingDelete {
                Text("Delete \"\(tunnel.name)\"? This removes its saved configuration.")
            }
        }
    }

    private var addTunnelMenu: some View {
        Menu {
            Button(action: onImportFiles) {
                Label(tr("addTunnelMenuImportFile"), systemImage: "doc.badge.plus")
            }
            Button(action: onScanQRCode) {
                Label(tr("addTunnelMenuQRCode"), systemImage: "qrcode.viewfinder")
            }
            Divider()
            Button(action: onPasteConfig) {
                Label("Paste configuration", systemImage: "doc.on.clipboard")
            }
        } label: {
            Image(systemName: "plus")
                .fontWeight(.semibold)
        }
        .accessibilityLabel("Add tunnel")
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Tunnels Yet", systemImage: "shield.lefthalf.filled")
        } description: {
            Text("Import a .conf file, a .zip archive, or scan a QR code to add your first tunnel.")
        } actions: {
            VStack(spacing: SGSpacing.small) {
                Button(action: onImportFiles) {
                    Label(tr("addTunnelMenuImportFile"), systemImage: "doc.badge.plus")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onScanQRCode) {
                    Label(tr("addTunnelMenuQRCode"), systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, SGSpacing.xSmall)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SGColor.surfacePrimary)
    }

    private var tunnelListContent: some View {
        List {
            if let errorBanner = store.lastActivationError {
                Section {
                    ActivationErrorCardView(banner: errorBanner) {
                        store.dismissActivationErrorBanner()
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if let activeTunnel = store.activeTunnel {
                Section {
                    ActiveTunnelCardView(
                        tunnel: activeTunnel,
                        displayState: store.displayState(for: activeTunnel),
                        onOpenDetail: { onSelectTunnel(activeTunnel) },
                        onDisconnect: { store.setTunnelActive(false, for: activeTunnel) }
                    )
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(store.tunnels, id: \.name) { tunnel in
                    TunnelRowView(
                        tunnel: tunnel,
                        displayState: store.displayState(for: tunnel),
                        onSelect: {
                            onSelectTunnel(tunnel)
                        },
                        onToggle: { isOn in
                            store.setTunnelActive(isOn, for: tunnel)
                        }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            tunnelPendingDelete = tunnel
                        } label: {
                            Label(tr("tunnelsListSwipeDeleteButtonTitle"), systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Tunnels")
            }
        }
        .listStyle(.insetGrouped)
        .animation(.snappy(duration: 0.25), value: store.activeTunnel?.name)
    }
}

private struct ActiveTunnelCardView: View {
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

private struct ActivationErrorCardView: View {
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
