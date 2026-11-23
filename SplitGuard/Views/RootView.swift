import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var store: TunnelStore

    @State private var navigationPath: [ObjectIdentifier] = []
    @State private var showFileImporter = false
    @State private var showQRScanner = false
    @State private var showPasteSheet = false
    @State private var showCreateTunnel = false
    @State private var showSettings = false
    @State private var presentedSplitDNSPrompt: SplitDNSSuggestionPrompt?

    private var isBlockingModalActive: Bool {
        showFileImporter || showQRScanner || showPasteSheet || showCreateTunnel || showSettings
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            TunnelListView(
                store: store,
                onSelectTunnel: { tunnel in
                    navigationPath.append(ObjectIdentifier(tunnel))
                },
                onImportFiles: {
                    showFileImporter = true
                },
                onScanQRCode: {
                    showQRScanner = true
                },
                onCreateFromScratch: {
                    showCreateTunnel = true
                },
                onPasteConfig: {
                    showPasteSheet = true
                },
                onOpenSettings: {
                    showSettings = true
                }
            )
            .navigationDestination(for: ObjectIdentifier.self) { tunnelID in
                if let tunnel = store.tunnel(for: tunnelID) {
                    TunnelDetailView(store: store, tunnel: tunnel) {
                        navigationPath.removeAll { $0 == tunnelID }
                    }
                } else {
                    VStack(spacing: 0) {
                        BrutalistHeaderBar(
                            title: "Tunnel Removed",
                            leading: {
                                BrutalistBackButton {
                                    navigationPath.removeAll { $0 == tunnelID }
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
            }
        }
        .tint(SGColor.accent)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: UTType.splitGuardImportTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                store.importFiles(from: urls)
            case .failure(let error):
                store.presentAlert(
                    title: tr("alertCantOpenInputConfFileTitle"),
                    message: error.localizedDescription
                )
            }
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerView(
                store: store,
                onSwitchToPaste: {
                    showQRScanner = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showPasteSheet = true
                    }
                }
            )
        }
        .sheet(isPresented: $showCreateTunnel) {
            TunnelEditorView(store: store)
        }
        .sheet(isPresented: $showPasteSheet) {
            PasteConfigSheet(store: store)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store)
        }
        .sheet(item: $presentedSplitDNSPrompt) { prompt in
            FirstRunSplitDNSSheet(store: store, prompt: prompt)
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
            store.importFromOpenedURL(url)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                store.refreshStatuses()
            case .inactive, .background:
                store.updateQuickActions()
            @unknown default:
                break
            }
        }
        .onChange(of: store.revision) { _, _ in
            let validIDs = Set(store.tunnels.map(ObjectIdentifier.init))
            navigationPath.removeAll { !validIDs.contains($0) }
        }
        .onChange(of: store.requestedNavigationTunnelID) { _, _ in
            navigateToRequestedTunnelIfNeeded()
        }
        .onChange(of: store.pendingSplitDNSSuggestion) { _, _ in
            scheduleSplitDNSPromptPresentationIfReady()
        }
        .onChange(of: isBlockingModalActive) { _, isActive in
            if !isActive {
                scheduleSplitDNSPromptPresentationIfReady(delay: 0.35)
            }
        }
        .onAppear {
            navigateToRequestedTunnelIfNeeded()
            scheduleSplitDNSPromptPresentationIfReady()
        }
    }

    private func navigateToRequestedTunnelIfNeeded() {
        guard let tunnelID = store.consumeRequestedNavigationTunnelID() else { return }
        guard store.tunnel(for: tunnelID) != nil else { return }
        if navigationPath.last != tunnelID {
            navigationPath = [tunnelID]
        }
    }

    private func scheduleSplitDNSPromptPresentationIfReady(delay: TimeInterval = 0.05) {
        guard let pending = store.pendingSplitDNSSuggestion,
              !isBlockingModalActive,
              presentedSplitDNSPrompt == nil else { return }
        let targetID = pending.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !isBlockingModalActive,
                  presentedSplitDNSPrompt == nil,
                  store.pendingSplitDNSSuggestion?.id == targetID else { return }
            presentedSplitDNSPrompt = store.pendingSplitDNSSuggestion
        }
    }
}
