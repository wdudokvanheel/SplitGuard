import SwiftUI

struct TunnelListView: View {
    let store: TunnelStore
    let onSelectTunnel: (TunnelContainer) -> Void
    let onImportFiles: () -> Void
    let onScanQRCode: () -> Void
    let onCreateFromScratch: () -> Void
    let onPasteConfig: () -> Void
    let onOpenSettings: () -> Void

    @State private var liveMetrics = TunnelLiveMetricsMonitor()
    @State private var isVisible = false
    @State private var tunnelPendingDelete: TunnelContainer?
    @State private var isSelecting = false
    @State private var selectedTunnelIDs: Set<ObjectIdentifier> = []
    @State private var showMultiDeleteConfirmation = false
    @State private var showAddTunnelSheet = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedTunnels: [TunnelContainer] {
        store.tunnels.filter { selectedTunnelIDs.contains(ObjectIdentifier($0)) }
    }

    private var featuredTunnel: TunnelContainer? {
        store.featuredTunnel
    }

    private var featuredStatus: TunnelStatus {
        featuredTunnel.map { store.status(for: $0) } ?? .inactive
    }

    private var multiDeleteDialogMessage: String {
        let count = selectedTunnels.count
        if count == 1 {
            return tr(format: "deleteTunnelConfirmationAlertButtonMessage (%d)", count)
        }
        return tr(format: "deleteTunnelsConfirmationAlertButtonMessage (%d)", count)
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
            let validIDs = Set(store.tunnels.map(ObjectIdentifier.init))
            selectedTunnelIDs.formIntersection(validIDs)
            if store.tunnels.isEmpty {
                isSelecting = false
            }
            syncLiveMetrics()
        }
        .onChange(of: featuredTunnel.map(ObjectIdentifier.init)) { _, _ in
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
        .confirmationDialog(
            multiDeleteDialogMessage,
            isPresented: $showMultiDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(tr("deleteTunnelsConfirmationAlertButtonTitle"), role: .destructive) {
                let targets = selectedTunnels
                store.deleteMultiple(tunnels: targets) { succeeded in
                    if succeeded {
                        exitSelectionMode()
                    }
                }
            }
            Button(tr("actionCancel"), role: .cancel) {}
        }
        .sheet(isPresented: $showAddTunnelSheet) {
            BrutalistAddTunnelSheet(
                onScanQRCode: onScanQRCode,
                onImportFiles: onImportFiles,
                onCreateFromScratch: onCreateFromScratch,
                onPasteConfig: onPasteConfig
            )
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
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: SGSpacing.medium) {
                    headerBar

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
                            displayState: store.displayState(for: featured),
                            isFavorite: store.isFavorite(featured),
                            rxText: liveMetrics.hasLiveStats ? liveMetrics.rxFormatted : "0 B",
                            txText: liveMetrics.hasLiveStats ? liveMetrics.txFormatted : "0 B",
                            handshakeText: liveMetrics.handshakeAgeText ?? "Pending",
                            onOpenDetail: { onSelectTunnel(featured) },
                            onToggleConnection: { isOn in
                                store.setTunnelActive(isOn, for: featured)
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
                        ForEach(Array(store.tunnels.enumerated()), id: \.element) { index, tunnel in
                            let tunnelID = ObjectIdentifier(tunnel)
                            TunnelRowView(
                                tunnel: tunnel,
                                displayState: store.displayState(for: tunnel),
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
                                    store.setTunnelActive(isOn, for: tunnel)
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
                .padding(.top, SGSpacing.small)
                .padding(.bottom, isSelecting ? 104 : SGSpacing.xxLarge)
            }
            .background(SGColor.surfacePrimary.ignoresSafeArea())
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: featuredTunnel.map(ObjectIdentifier.init))

            if isSelecting {
                multiSelectBottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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
                    accessibilityLabelText: tr("tunnelsListSelectButtonTitle"),
                    action: {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                            isSelecting = true
                            selectedTunnelIDs.removeAll()
                        }
                    }
                )

                BrutalistIconButton(
                    systemImage: "gearshape.fill",
                    accessibilityLabelText: tr("tunnelsListSettingsButtonTitle"),
                    action: onOpenSettings
                )

                addTunnelMenu
            }
        }
    }

    @ViewBuilder
    var selectionHeaderControls: some View {
        let allSelected = selectedTunnels.count == store.tunnels.count
        Button(allSelected ? "NONE" : "ALL") {
            selectedTunnelIDs = allSelected ? [] : Set(store.tunnels.map(ObjectIdentifier.init))
        }
        .font(SGTypography.displayCompact)
        .padding(.horizontal, SGSpacing.small)
        .frame(height: 40)
        .buttonStyle(BrutalistButtonStyle(fill: SGColor.popYellow, shadowOffset: SGShadow.small))

        Spacer(minLength: 4)

        Text(selectedTunnels.isEmpty ? "SELECT" : "\(selectedTunnels.count) SELECTED")
            .font(SGTypography.displaySection)
            .tracking(0.8)
            .foregroundStyle(SGColor.textPrimary)

        Spacer(minLength: 4)

        Button("DONE") { exitSelectionMode() }
            .font(SGTypography.displayCompact)
            .padding(.horizontal, SGSpacing.small)
            .frame(height: 40)
            .buttonStyle(
                BrutalistButtonStyle(
                    fill: SGColor.surfaceCard,
                    foreground: SGColor.textPrimary,
                    shadowOffset: SGShadow.small
                )
            )
    }

    var addTunnelMenu: some View {
        Button {
            showAddTunnelSheet = true
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

    var multiSelectBottomBar: some View {
        HStack(spacing: SGSpacing.small) {
            Text(
                selectedTunnels.isEmpty
                    ? "Tap tunnels to select"
                    : tr(format: "tunnelsListSelectedTitle (%d)", selectedTunnels.count)
            )
            .font(SGTypography.subheadline)
            .foregroundStyle(SGColor.textPrimary)

            Spacer()

            Button {
                showMultiDeleteConfirmation = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash.fill")
                        .font(.caption.weight(.bold))
                    Text("DELETE")
                        .font(SGTypography.displayCompact)
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
            .disabled(selectedTunnels.isEmpty)
        }
        .padding(SGSpacing.medium)
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.thick, shadowOffset: SGShadow.medium)
        .padding(.horizontal, SGSpacing.medium)
        .padding(.bottom, SGSpacing.small)
    }

    func syncLiveMetrics() {
        liveMetrics.update(tunnel: featuredTunnel, status: featuredStatus, isVisible: isVisible)
    }

    func toggleSelection(for tunnelID: ObjectIdentifier) {
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
