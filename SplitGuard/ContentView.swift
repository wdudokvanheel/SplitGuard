import Observation
import SwiftUI
import UniformTypeIdentifiers
import WireGuardKit

@Observable
final class Phase0TunnelController: TunnelsManagerListDelegate, TunnelsManagerActivationDelegate {
    private(set) var tunnels: [TunnelContainer] = []
    private(set) var statusSnapshot: [ObjectIdentifier: TunnelStatus] = [:]
    private(set) var isLoading = true
    private(set) var logLines: [String] = []
    var alertTitle: String?
    var alertMessage: String?

    private var manager: TunnelsManager?
    private var statusObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var logViewHelper: LogViewHelper?

    init() {
        logViewHelper = LogViewHelper(logFilePath: FileManager.logFileURL?.path)
        loadTunnels()
    }

    var backendVersion: String {
        WIREGUARD_GO_VERSION
    }

    func loadTunnels() {
        isLoading = true
        TunnelsManager.create { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let manager):
                    self.manager = manager
                    manager.tunnelsListDelegate = self
                    manager.activationDelegate = self
                    self.syncTunnelsFromManager()
                case .failure(let error):
                    self.present(error: error)
                }
            }
        }
    }

    func importConfFile(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            let name = url.deletingPathExtension().lastPathComponent
            importConfText(contents, named: name)
        } catch {
            present(title: "Import Failed", message: error.localizedDescription)
        }
    }

    func importConfText(_ text: String, named rawName: String) {
        guard let manager else {
            present(title: "Not Ready", message: "Tunnel manager is not loaded yet.")
            return
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            present(title: "Missing Name", message: "Enter a tunnel name before importing.")
            return
        }
        do {
            let config = try TunnelConfiguration(fromWgQuickConfig: text, called: name)
            manager.add(tunnelConfiguration: config) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.syncTunnelsFromManager()
                    case .failure(let error):
                        self.present(error: error)
                    }
                }
            }
        } catch {
            present(title: "Invalid Configuration", message: String(describing: error))
        }
    }

    func toggle(tunnel: TunnelContainer) {
        guard let manager else { return }
        switch tunnel.status {
        case .inactive, .waiting:
            manager.startActivation(of: tunnel)
        case .active, .activating, .reasserting, .restarting:
            manager.startDeactivation(of: tunnel)
        case .deactivating:
            break
        }
    }

    func delete(tunnel: TunnelContainer) {
        guard let manager else { return }
        manager.remove(tunnel: tunnel) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.present(error: error)
                }
                self?.syncTunnelsFromManager()
            }
        }
    }

    func status(for tunnel: TunnelContainer) -> TunnelStatus {
        statusSnapshot[ObjectIdentifier(tunnel)] ?? tunnel.status
    }

    func refreshLogs() {
        logViewHelper?.fetchLogEntriesSinceLastFetch { [weak self] entries in
            guard let self, !entries.isEmpty else { return }
            let formatted = entries.map { "[\($0.timestamp)] \($0.message)" }
            self.logLines.append(contentsOf: formatted)
            if self.logLines.count > 200 {
                self.logLines.removeFirst(self.logLines.count - 200)
            }
        }
    }

    // MARK: - TunnelsManagerListDelegate

    func tunnelAdded(at index: Int) {
        syncTunnelsFromManager()
    }

    func tunnelModified(at index: Int) {
        syncTunnelsFromManager()
    }

    func tunnelMoved(from oldIndex: Int, to newIndex: Int) {
        syncTunnelsFromManager()
    }

    func tunnelRemoved(at index: Int, tunnel: TunnelContainer) {
        syncTunnelsFromManager()
    }

    // MARK: - TunnelsManagerActivationDelegate

    func tunnelActivationAttemptFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationAttemptError) {
        present(error: error)
        refreshLogs()
    }

    func tunnelActivationAttemptSucceeded(tunnel: TunnelContainer) {
        refreshLogs()
    }

    func tunnelActivationFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationError) {
        present(error: error)
        refreshLogs()
    }

    func tunnelActivationSucceeded(tunnel: TunnelContainer) {
        refreshLogs()
    }

    private func syncTunnelsFromManager() {
        guard let manager else { return }
        let list = manager.mapTunnels { $0 }
        tunnels = list

        let activeIDs = Set(list.map(ObjectIdentifier.init))
        statusObservations = statusObservations.filter { activeIDs.contains($0.key) }
        statusSnapshot = statusSnapshot.filter { activeIDs.contains($0.key) }

        for tunnel in list {
            let id = ObjectIdentifier(tunnel)
            statusSnapshot[id] = tunnel.status
            if statusObservations[id] == nil {
                statusObservations[id] = tunnel.observe(\.status, options: [.initial, .new]) { [weak self] container, _ in
                    DispatchQueue.main.async {
                        self?.statusSnapshot[ObjectIdentifier(container)] = container.status
                        self?.refreshLogs()
                    }
                }
            }
        }
    }

    private func present(error: WireGuardAppError) {
        let alert = error.alertText
        present(title: alert.title, message: alert.message)
    }

    private func present(title: String, message: String) {
        alertTitle = title
        alertMessage = message
    }
}

struct ContentView: View {
    @State private var controller = Phase0TunnelController()
    @State private var showFileImporter = false
    @State private var showPasteSheet = false
    @State private var pasteName = ""
    @State private var pasteConfig = ""

    private var supportedConfTypes: [UTType] {
        var types: [UTType] = [.plainText, .text]
        if let confType = UTType(filenameExtension: "conf") {
            types.insert(confType, at: 0)
        }
        return types
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Phase 0 — Tunnel Proof") {
                    LabeledContent("wireguard-go", value: controller.backendVersion)
                    LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "unknown")
                    LabeledContent("App Group", value: FileManager.appGroupId ?? "missing")
                }

                Section("Tunnels") {
                    if controller.isLoading {
                        ProgressView("Loading tunnels…")
                    } else if controller.tunnels.isEmpty {
                        Text("Import a .conf file or paste a WireGuard configuration to test the tunnel.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(controller.tunnels, id: \.name) { tunnel in
                            tunnelRow(tunnel)
                        }
                    }
                }

                Section {
                    if controller.logLines.isEmpty {
                        Text("No log entries yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(controller.logLines.suffix(40).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    HStack {
                        Text("Extension & App Log")
                        Spacer()
                        Button("Refresh") {
                            controller.refreshLogs()
                        }
                        .font(.caption)
                    }
                }
            }
            .navigationTitle("SplitGuard")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showPasteSheet = true
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: supportedConfTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        controller.importConfFile(from: url)
                    }
                case .failure(let error):
                    controller.alertTitle = "File Picker Error"
                    controller.alertMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showPasteSheet) {
                pasteSheet
            }
            .alert(
                controller.alertTitle ?? "Error",
                isPresented: Binding(
                    get: { controller.alertTitle != nil },
                    set: { isPresented in
                        if !isPresented {
                            controller.alertTitle = nil
                            controller.alertMessage = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(controller.alertMessage ?? "")
            }
            .onOpenURL { url in
                controller.importConfFile(from: url)
            }
            .onAppear {
                controller.refreshLogs()
            }
        }
    }

    private func tunnelRow(_ tunnel: TunnelContainer) -> some View {
        let status = controller.status(for: tunnel)
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(tunnel.name)
                    .font(.headline)
                Text(statusLabel(status))
                    .font(.caption)
                    .foregroundStyle(status == .active ? .green : .secondary)
            }
            Spacer()
            Button(actionLabel(status)) {
                controller.toggle(tunnel: tunnel)
            }
            .buttonStyle(.borderedProminent)
            .tint(status == .active ? .red : .accentColor)
            .disabled(status == .deactivating)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) {
                controller.delete(tunnel: tunnel)
            }
        }
    }

    private var pasteSheet: some View {
        NavigationStack {
            Form {
                Section("Tunnel Name") {
                    TextField("e.g. hw45", text: $pasteName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("wg-quick .conf") {
                    TextEditor(text: $pasteConfig)
                        .font(.caption.monospaced())
                        .frame(minHeight: 240)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Paste Config")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showPasteSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        controller.importConfText(pasteConfig, named: pasteName)
                        pasteName = ""
                        pasteConfig = ""
                        showPasteSheet = false
                    }
                }
            }
        }
    }

    private func statusLabel(_ status: TunnelStatus) -> String {
        switch status {
        case .inactive: return "Inactive"
        case .activating: return "Connecting…"
        case .active: return "Connected"
        case .deactivating: return "Disconnecting…"
        case .reasserting: return "Reasserting…"
        case .restarting: return "Restarting…"
        case .waiting: return "Waiting…"
        }
    }

    private func actionLabel(_ status: TunnelStatus) -> String {
        switch status {
        case .inactive, .waiting: return "Connect"
        case .active, .activating, .reasserting, .restarting: return "Disconnect"
        case .deactivating: return "…"
        }
    }
}
