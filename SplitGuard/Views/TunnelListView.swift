import SwiftUI

struct TunnelListView: View {
    let store: TunnelStore
    let onSelectTunnel: (Tunnel) -> Void
    let onAddTunnel: () -> Void
    let onImportFiles: () -> Void
    let onScanQRCode: () -> Void
    let onCreateFromScratch: () -> Void
    let onPasteConfig: () -> Void
    let onOpenSettings: () -> Void

    @State private var liveMetrics = TunnelLiveMetricsMonitor()
    @State private var isVisible = false
    @State private var tunnelPendingDelete: Tunnel?
    @State private var isSelecting = false
    @State private var selectedTunnelIDs: Set<Tunnel.ID> = []
    @State private var showMultiDeleteConfirmation = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedTunnels: [Tunnel] {
        store.tunnels.filter { selectedTunnelIDs.contains($0.id) }
    }

    private var featuredTunnel: Tunnel? {
        store.featuredTunnel
    }

    private var featuredStatus: TunnelStatus {
        featuredTunnel.map { store.status(for: $0) } ?? .inactive
    }

    private var multiDeleteDialogMessage: String {
        let count = selectedTunnels.count
        return String(
            localized: "tunnels.delete.confirmCount",
            defaultValue: "Delete \(count) tunnels?"
        )
    }

    var body: some View {
        Group {
            if store.isLoading {
                loadingView
            } else if store.tunnels.isEmpty {
                FirstRunOnboardingView(
                    onScanQRCode: onScanQRCode,
                    onImportFiles: onImportFiles,
                    onCreateFromScratch: onCreateFromScratch,
                    onPasteConfig: onPasteConfig,
                    onOpenSettings: onOpenSettings
                )
            } else {
                tunnelListContent
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            isVisible = true
            syncLiveMetrics()
        }
        .onDisappear {
            isVisible = false
            liveMetrics.stop()
        }
        .onChange(of: store.revision) { _, _ in
            let validIDs = Set(store.tunnels.map(\.id))
            selectedTunnelIDs.formIntersection(validIDs)
            if store.tunnels.isEmpty {
                isSelecting = false
            }
            syncLiveMetrics()
        }
        .onChange(of: featuredTunnel?.id) { _, _ in
            syncLiveMetrics()
        }
        .onChange(of: featuredStatus) { _, _ in
            syncLiveMetrics()
        }
        .confirmationDialog(
            "Delete Tunnel",
            isPresented: Binding(
                get: { tunnelPendingDelete != nil },
                set: { if !$0 { tunnelPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let tunnel = tunnelPendingDelete {
                Button(String(localized: "action.delete", defaultValue: "Delete"), role: .destructive) {
                    Task {
                        _ = await store.delete(tunnel: tunnel)
                    }
                    tunnelPendingDelete = nil
                }
            }
            Button(String(localized: "action.cancel", defaultValue: "Cancel"), role: .cancel) {
                tunnelPendingDelete = nil
            }
        } message: {
            if let tunnel = tunnelPendingDelete {
                Text("Delete \"\(tunnel.name)\"? This removes its saved configuration.")
            }
        }
        .confirmationDialog(
            multiDeleteDialogMessage,
            isPresented: $showMultiDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "action.delete", defaultValue: "Delete"), role: .destructive) {
                let targets = selectedTunnels
                Task {
                    let succeeded = await store.deleteMultiple(tunnels: targets)
                    if succeeded {
                        exitSelectionMode()
                    }
                }
            }
            Button(String(localized: "action.cancel", defaultValue: "Cancel"), role: .cancel) {}
        }
    }
}

private extension TunnelListView {
    var loadingView: some View {
        VStack(spacing: SGSpacing.medium) {
            ProgressView()
                .controlSize(.large)
                .tint(SGColor.textPrimary)
            Text("LOADING TUNNELS…")
                .font(SGTypography.displayCompact)
                .tracking(1.2)
                .foregroundStyle(SGColor.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SGColor.surfacePrimary.ignoresSafeArea())
    }

    var tunnelListContent: some View {
        VStack(spacing: 0) {
            topBar

            ScrollView {
                VStack(spacing: SGSpacing.medium) {
                    if !isSelecting, let errorBanner = store.lastActivationError {
                        ActivationErrorCardView(banner: errorBanner) {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                                store.dismissActivationErrorBanner()
                            }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if !isSelecting, let featured = featuredTunnel {
                        FeaturedTunnelHeroCardView(
                            tunnel: featured,
                            displayState: store.displayState(
                                for: featured,
                                healthState: liveMetrics.healthState(for: featured)
                            ),
                            isFavorite: store.isFavorite(featured),
                            rxText: liveMetrics.hasLiveStats ? liveMetrics.rxFormatted : "0 B",
                            txText: liveMetrics.hasLiveStats ? liveMetrics.txFormatted : "0 B",
                            handshakeText: liveMetrics.handshakeSummaryText(for: featured),
                            onOpenDetail: { onSelectTunnel(featured) },
                            onToggleConnection: { isOn in
                                Task {
                                    await store.setTunnelActive(isOn, for: featured)
                                }
                            },
                            onToggleFavorite: {
                                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                                    store.toggleFavorite(featured)
                                }
                            }
                        )
                    }

                    BrutalistSectionBar(
                        title: isSelecting ? "Select Tunnels" : "Tunnels",
                        trailingText: "\(store.tunnels.count)"
                    )

                    LazyVStack(spacing: SGSpacing.small) {
                        ForEach(Array(store.tunnels.enumerated()), id: \.element.id) { index, tunnel in
                            let tunnelID = tunnel.id
                            TunnelRowView(
                                tunnel: tunnel,
                                displayState: store.displayState(
                                    for: tunnel,
                                    healthState: liveMetrics.healthState(for: tunnel)
                                ),
                                rowIndex: index,
                                isFavorite: store.isFavorite(tunnel),
                                isSelecting: isSelecting,
                                isSelected: selectedTunnelIDs.contains(tunnelID),
                                onSelect: {
                                    if isSelecting {
                                        toggleSelection(for: tunnelID)
                                    } else {
                                        onSelectTunnel(tunnel)
                                    }
                                },
                                onToggle: { isOn in
                                    Task {
                                        await store.setTunnelActive(isOn, for: tunnel)
                                    }
                                },
                                onToggleFavorite: {
                                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                                        store.toggleFavorite(tunnel)
                                    }
                                },
                                onDelete: {
                                    tunnelPendingDelete = tunnel
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, SGSpacing.medium)
                .padding(.top, SGSpacing.medium)
                .padding(.bottom, SGSpacing.xxLarge)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .background(SGColor.surfacePrimary.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting {
                    MultiSelectBottomBarView(selectedCount: selectedTunnels.count) {
                        showMultiDeleteConfirmation = true
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: featuredTunnel?.id)
    }

    var topBar: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, SGSpacing.medium)
                .padding(.vertical, SGSpacing.small)
                .background(SGColor.surfacePrimary)

            Rectangle()
                .fill(SGColor.borderInk)
                .frame(height: SGBorder.regular)
        }
    }

    var headerBar: some View {
        HStack(spacing: SGSpacing.xSmall) {
            if isSelecting {
                selectionHeaderControls
            } else {
                HStack(spacing: 3) {
                    Text("SPLIT")
                        .foregroundStyle(SGColor.textPrimary)
                    Text("GUARD")
                        .foregroundStyle(SGColor.popRed)
                }
                .font(SGTypography.displayHero)
                .tracking(0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                Spacer(minLength: SGSpacing.xxSmall)

                BrutalistIconButton(
                    systemImage: "checklist",
                    accessibilityLabelText: String(localized: "tunnels.list.select", defaultValue: "Select"),
                    action: {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                            isSelecting = true
                            selectedTunnelIDs.removeAll()
                        }
                    }
                )

                BrutalistIconButton(
                    systemImage: "gearshape.fill",
                    accessibilityLabelText: String(localized: "settings.title", defaultValue: "Settings"),
                    action: onOpenSettings
                )

                addTunnelMenu
            }
        }
    }

    @ViewBuilder
    var selectionHeaderControls: some View {
        let allSelected = selectedTunnels.count == store.tunnels.count
        Button {
            selectedTunnelIDs = allSelected ? [] : Set(store.tunnels.map(\.id))
        } label: {
            Text(allSelected ? "NONE" : "ALL")
                .font(SGTypography.displayCompact)
                .tracking(0.8)
                .padding(.horizontal, SGSpacing.small)
                .frame(height: 40)
        }
        .buttonStyle(
            BrutalistButtonStyle(
                fill: SGColor.popYellow,
                foreground: SGColor.inkOnPop,
                borderWidth: SGBorder.regular,
                shadowOffset: SGShadow.small,
                cornerRadius: SGRadius.sharp
            )
        )

        Spacer(minLength: 4)

        Text(selectedTunnels.isEmpty ? "SELECT" : "\(selectedTunnels.count) SELECTED")
            .font(SGTypography.displaySection)
            .tracking(0.8)
            .foregroundStyle(SGColor.textPrimary)

        Spacer(minLength: 4)

        Button {
            exitSelectionMode()
        } label: {
            Text("DONE")
                .font(SGTypography.displayCompact)
                .tracking(0.8)
                .padding(.horizontal, SGSpacing.small)
                .frame(height: 40)
        }
        .buttonStyle(
            BrutalistButtonStyle(
                fill: SGColor.surfaceCard,
                foreground: SGColor.textPrimary,
                borderWidth: SGBorder.regular,
                shadowOffset: SGShadow.small,
                cornerRadius: SGRadius.sharp
            )
        )
    }

    var addTunnelMenu: some View {
        Button {
            onAddTunnel()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .black))
                Text("ADD")
                    .font(SGTypography.displayCompact)
                    .tracking(0.8)
            }
            .padding(.horizontal, SGSpacing.small)
            .frame(height: 40)
        }
        .buttonStyle(
            BrutalistButtonStyle(
                fill: SGColor.popRed,
                foreground: SGColor.pureWhite,
                borderWidth: SGBorder.regular,
                shadowOffset: SGShadow.small,
                cornerRadius: SGRadius.sharp
            )
        )
        .accessibilityLabel("Add tunnel")
    }

    func syncLiveMetrics() {
        liveMetrics.update(tunnel: featuredTunnel, status: featuredStatus, store: store, isVisible: isVisible)
    }

    func toggleSelection(for tunnelID: Tunnel.ID) {
        if selectedTunnelIDs.contains(tunnelID) {
            selectedTunnelIDs.remove(tunnelID)
        } else {
            selectedTunnelIDs.insert(tunnelID)
        }
    }

    func exitSelectionMode() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            isSelecting = false
            selectedTunnelIDs.removeAll()
        }
    }
}
