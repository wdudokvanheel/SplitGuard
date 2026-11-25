import SplitGuardCore
import SwiftUI
import UniformTypeIdentifiers

enum AppRoute: Hashable {
    case tunnelDetail(Tunnel.ID)
    case addTunnel
    case qrScanner
    case createTunnel
    case editTunnel(Tunnel.ID)
    case pasteConfig
    case nameImportedTunnel
    case settings
    case about
    case logViewer
    #if DEBUG
    case debugVerificationWizard
    #endif
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var store: TunnelStore

    @State private var navigationPath: [AppRoute] = []
    @State private var showFileImporter = false
    @State private var pendingImportedProfile: TunnelProfile?

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
                Task {
                    await handleFileImportSelection(urls)
                }
            case .failure(let error):
                store.presentAlert(
                    title: String(localized: "alert.import.cantOpenFile.title", defaultValue: "Unable to import from file"),
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
            Button(String(localized: "action.ok", defaultValue: "OK"), role: .cancel) {
                store.dismissActiveAlert()
            }
        } message: {
            Text(store.activeAlert?.message ?? "")
        }
        .onOpenURL { url in
            Task {
                await handleOpenedURL(url)
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
        .onAppear {
            navigateToRequestedTunnelIfNeeded()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(DebugVerificationWizardModel.autoRunLaunchFlag) {
                if navigationPath.last != .debugVerificationWizard {
                    navigationPath = [.debugVerificationWizard]
                }
                Task {
                    await DebugVerificationWizardModel.shared.runAutomatedSuiteForCLI(store: store)
                }
            }
            #endif
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
        case .nameImportedTunnel:
            nameImportedTunnelDestination
        case .settings, .about, .logViewer:
            utilityDestination(for: route)
        #if DEBUG
        case .debugVerificationWizard:
            utilityDestination(for: route)
        #endif
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
        #if DEBUG
        case .debugVerificationWizard:
            DebugVerificationWizardView(store: store)
        #endif
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

    @ViewBuilder
    private var nameImportedTunnelDestination: some View {
        if let profile = pendingImportedProfile {
            NameImportedTunnelRouteView(
                store: store,
                profile: profile,
                onCancel: {
                    pendingImportedProfile = nil
                    navigationPath.removeAll { $0 == .nameImportedTunnel }
                },
                onSaved: {
                    pendingImportedProfile = nil
                    navigationPath.removeAll()
                }
            )
        } else {
            Color.clear
                .onAppear {
                    navigationPath.removeAll { $0 == .nameImportedTunnel }
                }
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
}

private extension RootView {
    func tunnelRemovedView(for tunnelID: Tunnel.ID) -> some View {
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

    func removeTunnelRoutes(for tunnelID: Tunnel.ID) {
        navigationPath.removeAll { route in
            route == .tunnelDetail(tunnelID) || route == .editTunnel(tunnelID)
        }
    }

    func navigateToRequestedTunnelIfNeeded() {
        guard let tunnelID = store.consumeRequestedNavigationTunnelID() else { return }
        guard store.tunnel(for: tunnelID) != nil else { return }
        if navigationPath.last != .tunnelDetail(tunnelID) {
            navigationPath = [.tunnelDetail(tunnelID)]
        }
    }

    func handleFileImportSelection(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        if urls.count == 1 {
            let outcome = await TunnelImportService.importFiles(from: urls)
            if outcome.profiles.count == 1, outcome.failures.isEmpty {
                presentNamePrompt(for: outcome.profiles[0])
            } else {
                store.presentImportFailures(outcome.failures, importedCount: 0, totalCount: 1)
            }
            return
        }

        navigationPath.removeAll { $0 == .addTunnel }
        await store.importFiles(from: urls)
    }

    func handleOpenedURL(_ url: URL) async {
        guard store.hasLoaded else {
            await store.importFromOpenedURL(url)
            return
        }

        let isInboxFile = url.pathComponents.contains("Inbox")
        let outcome = await TunnelImportService.importFiles(from: [url])
        if isInboxFile {
            try? FileManager.default.removeItem(at: url)
        }

        if outcome.profiles.count == 1, outcome.failures.isEmpty {
            presentNamePrompt(for: outcome.profiles[0])
        } else {
            store.presentImportFailures(outcome.failures, importedCount: 0, totalCount: 1)
        }
    }

    func presentNamePrompt(for profile: TunnelProfile) {
        pendingImportedProfile = profile
        navigationPath.removeAll { $0 == .addTunnel || $0 == .nameImportedTunnel }
        navigationPath.append(.nameImportedTunnel)
    }
}
