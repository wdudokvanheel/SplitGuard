import SwiftUI

struct TunnelListView: View {
    let store: TunnelStore
    let onSelectTunnel: (TunnelContainer) -> Void
    let onImportFiles: () -> Void
    let onScanQRCode: () -> Void
    let onCreateFromScratch: () -> Void
    let onPasteConfig: () -> Void
    let onOpenSettings: () -> Void

    @State private var tunnelPendingDelete: TunnelContainer?
    @State private var isSelecting = false
    @State private var selectedTunnelIDs: Set<ObjectIdentifier> = []
    @State private var showMultiDeleteConfirmation = false

    private var selectedTunnels: [TunnelContainer] {
        store.tunnels.filter { selectedTunnelIDs.contains(ObjectIdentifier($0)) }
    }

    private var navigationTitleText: String {
        if isSelecting && !selectedTunnels.isEmpty {
            return tr(format: "tunnelsListSelectedTitle (%d)", selectedTunnels.count)
        }
        return "SplitGuard"
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
                ProgressView("Loading tunnels…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SGColor.surfacePrimary)
            } else if store.tunnels.isEmpty {
                emptyStateView
            } else {
                tunnelListContent
            }
        }
        .navigationTitle(navigationTitleText)
        .toolbar {
            leadingToolbarItem
            trailingToolbarItems
            bottomMultiSelectToolbar
        }
        .onChange(of: store.revision) { _, _ in
            let validIDs = Set(store.tunnels.map(ObjectIdentifier.init))
            selectedTunnelIDs.formIntersection(validIDs)
            if store.tunnels.isEmpty {
                isSelecting = false
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
    }
}

private extension TunnelListView {
    @ToolbarContentBuilder
    var leadingToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isSelecting {
                if selectedTunnels.count == store.tunnels.count && !store.tunnels.isEmpty {
                    Button("Deselect All") {
                        selectedTunnelIDs.removeAll()
                    }
                } else {
                    Button(tr("tunnelsListSelectAllButtonTitle")) {
                        selectedTunnelIDs = Set(store.tunnels.map(ObjectIdentifier.init))
                    }
                }
            } else {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(tr("tunnelsListSettingsButtonTitle"))
            }
        }
    }

    @ToolbarContentBuilder
    var trailingToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if isSelecting {
                Button(tr("actionCancel")) {
                    exitSelectionMode()
                }
            } else {
                if !store.tunnels.isEmpty {
                    Button(tr("tunnelsListSelectButtonTitle")) {
                        withAnimation(.snappy(duration: 0.2)) {
                            isSelecting = true
                            selectedTunnelIDs.removeAll()
                        }
                    }
                }
                addTunnelMenu
            }
        }
    }

    @ToolbarContentBuilder
    var bottomMultiSelectToolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Text(
                        selectedTunnels.isEmpty
                            ? "Select tunnels to delete"
                            : tr(format: "tunnelsListSelectedTitle (%d)", selectedTunnels.count)
                    )
                    .font(SGTypography.subheadline)
                    .foregroundStyle(SGColor.textSecondary)

                    Spacer()

                    Button(role: .destructive) {
                        showMultiDeleteConfirmation = true
                    } label: {
                        Label(tr("tunnelsListDeleteButtonTitle"), systemImage: "trash")
                    }
                    .disabled(selectedTunnels.isEmpty)
                }
            }
        }
    }

    var addTunnelMenu: some View {
        Menu {
            Button(action: onImportFiles) {
                Label(tr("addTunnelMenuImportFile"), systemImage: "doc.badge.plus")
            }
            Button(action: onScanQRCode) {
                Label(tr("addTunnelMenuQRCode"), systemImage: "qrcode.viewfinder")
            }
            Button(action: onCreateFromScratch) {
                Label(tr("addTunnelMenuFromScratch"), systemImage: "square.and.pencil")
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

    var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Tunnels Yet", systemImage: "shield.lefthalf.filled")
        } description: {
            Text("Import a .conf or .zip file, scan a QR code, or create a configuration from scratch.")
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

                Button(action: onCreateFromScratch) {
                    Label(tr("addTunnelMenuFromScratch"), systemImage: "square.and.pencil")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, SGSpacing.xSmall)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SGColor.surfacePrimary)
    }

    var tunnelListContent: some View {
        List {
            if !isSelecting, let errorBanner = store.lastActivationError {
                Section {
                    ActivationErrorCardView(banner: errorBanner) {
                        store.dismissActivationErrorBanner()
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if !isSelecting, let activeTunnel = store.activeTunnel {
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
                ForEach(store.tunnels, id: \.self) { tunnel in
                    let tunnelID = ObjectIdentifier(tunnel)
                    TunnelRowView(
                        tunnel: tunnel,
                        displayState: store.displayState(for: tunnel),
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
                        }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !isSelecting {
                            Button(role: .destructive) {
                                tunnelPendingDelete = tunnel
                            } label: {
                                Label(tr("tunnelsListSwipeDeleteButtonTitle"), systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("Tunnels")
            }
        }
        .listStyle(.insetGrouped)
        .animation(.snappy(duration: 0.25), value: store.activeTunnel.map(ObjectIdentifier.init))
    }

    func toggleSelection(for tunnelID: ObjectIdentifier) {
        if selectedTunnelIDs.contains(tunnelID) {
            selectedTunnelIDs.remove(tunnelID)
        } else {
            selectedTunnelIDs.insert(tunnelID)
        }
    }

    func exitSelectionMode() {
        withAnimation(.snappy(duration: 0.2)) {
            isSelecting = false
            selectedTunnelIDs.removeAll()
        }
    }
}
