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
                    ContentUnavailableView(
                        "Tunnel Removed",
                        systemImage: "shield.slash",
                        description: Text("This tunnel is no longer available.")
                    )
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
        .onAppear {
            navigateToRequestedTunnelIfNeeded()
        }
    }

    private func navigateToRequestedTunnelIfNeeded() {
        guard let tunnelID = store.consumeRequestedNavigationTunnelID() else { return }
        guard store.tunnel(for: tunnelID) != nil else { return }
        if navigationPath.last != tunnelID {
            navigationPath = [tunnelID]
        }
    }
}
