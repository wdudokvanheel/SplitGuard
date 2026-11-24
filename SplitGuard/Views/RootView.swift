import SwiftUI
import UniformTypeIdentifiers

enum AppRoute: Hashable {
    case tunnelDetail(Tunnel.ID)
    case addTunnel
    case qrScanner
    case createTunnel
    case editTunnel(Tunnel.ID)
    case pasteConfig
    case settings
    case about
    case logViewer
    case splitDNSSuggestion(SplitDNSSuggestionPrompt)
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var store: TunnelStore

    @State private var navigationPath: [AppRoute] = []
    @State private var showFileImporter = false

    private var isBlockingRouteActive: Bool {
        showFileImporter || navigationPath.contains { route in
            switch route {
            case .tunnelDetail:
                return false
            case .addTunnel, .qrScanner, .createTunnel, .editTunnel,
                 .pasteConfig, .settings, .about, .logViewer, .splitDNSSuggestion:
                return true
            }
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            TunnelListView(
                store: store,
                onSelectTunnel: { tunnel in
                    navigationPath.append(.tunnelDetail(tunnel.id))
                },
                onAddTunnel: {
                    navigationPath.append(.addTunnel)
                },
                onImportFiles: {
                    showFileImporter = true
                },
                onScanQRCode: {
                    navigationPath.append(.qrScanner)
                },
                onCreateFromScratch: {
                    navigationPath.append(.createTunnel)
                },
                onPasteConfig: {
                    navigationPath.append(.pasteConfig)
                },
                onOpenSettings: {
                    navigationPath.append(.settings)
                }
            )
            .navigationDestination(for: AppRoute.self) { route in
                destinationView(for: route)
            }
        }
        .tint(SGColor.accent)
        .background {
            WindowAppearanceBridge(mode: store.appearanceMode)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: UTType.splitGuardImportTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                navigationPath.removeAll { $0 == .addTunnel }
                Task {
                    await store.importFiles(from: urls)
                }
            case .failure(let error):
                store.presentAlert(
                    title: tr("alertCantOpenInputConfFileTitle"),
                    message: error.localizedDescription
                )
            }
        }
        .alert(
            store.activeAlert?.title ?? "",
            isPresented: Binding(
                get: { store.activeAlert != nil },
                set: { isPresented in
                    if !isPresented {
                        store.dismissActiveAlert()
                    }
                }
            )
        ) {
            Button(tr("actionOK"), role: .cancel) {
                store.dismissActiveAlert()
            }
        } message: {
            Text(store.activeAlert?.message ?? "")
        }
        .onOpenURL { url in
            Task {
                await store.importFromOpenedURL(url)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task {
                    await store.refreshStatuses()
                }
            case .inactive, .background:
                store.updateQuickActions()
            @unknown default:
                break
            }
        }
        .onChange(of: store.revision) { _, _ in
            let validIDs = Set(store.tunnels.map(\.id))
            navigationPath.removeAll { route in
                switch route {
                case .tunnelDetail(let tunnelID), .editTunnel(let tunnelID):
                    return !validIDs.contains(tunnelID)
                default:
                    return false
                }
            }
        }
        .onChange(of: store.requestedNavigationTunnelID) { _, _ in
            navigateToRequestedTunnelIfNeeded()
        }
        .onChange(of: store.pendingSplitDNSSuggestion) { _, _ in
            scheduleSplitDNSPromptPresentationIfReady()
        }
        .onChange(of: isBlockingRouteActive) { _, isActive in
            if !isActive {
                scheduleSplitDNSPromptPresentationIfReady(delay: 0.35)
            }
        }
        .onAppear {
            navigateToRequestedTunnelIfNeeded()
            scheduleSplitDNSPromptPresentationIfReady()
        }
    }

    @ViewBuilder
    private func destinationView(for route: AppRoute) -> some View {
        switch route {
        case .tunnelDetail(let tunnelID):
            tunnelDetailDestination(for: tunnelID)
        case .editTunnel(let tunnelID):
            editTunnelDestination(for: tunnelID)
        case .addTunnel:
            BrutalistAddTunnelSheet(
                onScanQRCode: { navigationPath.append(.qrScanner) },
                onImportFiles: { showFileImporter = true },
                onCreateFromScratch: { navigationPath.append(.createTunnel) },
                onPasteConfig: { navigationPath.append(.pasteConfig) }
            )
        case .qrScanner:
            qrScannerDestination
        case .createTunnel:
            TunnelEditorView(store: store) { _ in navigationPath.removeAll() }
        case .pasteConfig:
            PasteConfigSheet(store: store) { navigationPath.removeAll() }
        case .splitDNSSuggestion(let prompt):
            FirstRunSplitDNSSheet(store: store, prompt: prompt)
        case .settings, .about, .logViewer:
            utilityDestination(for: route)
        }
    }

    @ViewBuilder
    private func utilityDestination(for route: AppRoute) -> some View {
        switch route {
        case .settings:
            SettingsView(store: store)
        case .about:
            AboutView()
        case .logViewer:
            LogViewerView()
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func tunnelDetailDestination(for tunnelID: Tunnel.ID) -> some View {
        if let tunnel = store.tunnel(for: tunnelID) {
            TunnelDetailView(
                store: store,
                tunnel: tunnel,
                onEdit: { navigationPath.append(.editTunnel(tunnelID)) },
                onDeleted: { removeTunnelRoutes(for: tunnelID) }
            )
        } else {
            tunnelRemovedView(for: tunnelID)
        }
    }

    @ViewBuilder
    private func editTunnelDestination(for tunnelID: Tunnel.ID) -> some View {
        if let tunnel = store.tunnel(for: tunnelID) {
            TunnelEditorView(store: store, tunnel: tunnel)
        } else {
            tunnelRemovedView(for: tunnelID)
        }
    }

    private var qrScannerDestination: some View {
        QRScannerView(
            store: store,
            onSwitchToPaste: {
                if navigationPath.last == .qrScanner {
                    navigationPath[navigationPath.count - 1] = .pasteConfig
                } else {
                    navigationPath.append(.pasteConfig)
                }
            },
            onCompleted: { navigationPath.removeAll() }
        )
    }

    private func tunnelRemovedView(for tunnelID: Tunnel.ID) -> some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: "Tunnel Removed",
                enableSwipeBack: true,
                leading: {
                    BrutalistBackButton {
                        removeTunnelRoutes(for: tunnelID)
                    }
                }
            )
            BrutalistUnavailableCard(
                title: "Tunnel Removed",
                message: "This tunnel is no longer available.",
                systemImage: "shield.slash.fill",
                accent: SGColor.popRed
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func removeTunnelRoutes(for tunnelID: Tunnel.ID) {
        navigationPath.removeAll { route in
            route == .tunnelDetail(tunnelID) || route == .editTunnel(tunnelID)
        }
    }

    private func navigateToRequestedTunnelIfNeeded() {
        guard let tunnelID = store.consumeRequestedNavigationTunnelID() else { return }
        guard store.tunnel(for: tunnelID) != nil else { return }
        if navigationPath.last != .tunnelDetail(tunnelID) {
            navigationPath = [.tunnelDetail(tunnelID)]
        }
    }

    private func scheduleSplitDNSPromptPresentationIfReady(delay: TimeInterval = 0.05) {
        guard let pending = store.pendingSplitDNSSuggestion,
              !isBlockingRouteActive else { return }
        let targetID = pending.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !isBlockingRouteActive,
                  let current = store.pendingSplitDNSSuggestion,
                  current.id == targetID else { return }
            navigationPath.append(.splitDNSSuggestion(current))
        }
    }
}
