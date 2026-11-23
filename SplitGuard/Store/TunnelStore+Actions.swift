import Foundation
import WireGuardKit

extension TunnelStore {
    func saveTunnel(
        existing tunnel: TunnelContainer?,
        configuration: TunnelConfiguration,
        splitDNSConfiguration: SplitDNSConfiguration = .allDomains,
        onDemandOption: ActivateOnDemandOption,
        completion: @escaping (Result<TunnelContainer, TunnelsManagerError>) -> Void
    ) {
        guard let manager else {
            completion(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }

        if let tunnel {
            manager.modify(
                tunnel: tunnel,
                tunnelConfiguration: configuration,
                splitDNSConfiguration: splitDNSConfiguration,
                onDemandOption: onDemandOption
            ) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        completion(.failure(error))
                    } else {
                        self.syncTunnelsFromManager()
                        completion(.success(tunnel))
                    }
                }
            }
        } else {
            manager.add(
                tunnelConfiguration: configuration,
                splitDNSConfiguration: splitDNSConfiguration,
                onDemandOption: onDemandOption
            ) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let createdTunnel):
                        self.syncTunnelsFromManager()
                        completion(.success(createdTunnel))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func deleteMultiple(tunnels tunnelsToDelete: [TunnelContainer], completion: ((Bool) -> Void)? = nil) {
        guard let manager, !tunnelsToDelete.isEmpty else {
            completion?(false)
            return
        }
        let deletedNames = tunnelsToDelete.map(\.name)
        manager.removeMultiple(tunnels: tunnelsToDelete) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.present(error: error)
                    self.syncTunnelsFromManager()
                    completion?(false)
                } else {
                    for name in deletedNames {
                        self.clearActivationError(for: name)
                    }
                    self.syncTunnelsFromManager()
                    completion?(true)
                }
            }
        }
    }

    func exportAllTunnelsZip(completion: @escaping (Result<URL, AlertItem>) -> Void) {
        let entries: [(TunnelConfiguration, SplitDNSConfiguration)] = tunnels.compactMap { tunnel in
            guard let configuration = tunnel.tunnelConfiguration else { return nil }
            return (configuration, tunnel.splitDNSConfiguration)
        }
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("splitguard-export.zip")
        _ = FileManager.deleteFile(at: destinationURL)

        ZipExporter.exportConfigFiles(entries: entries, to: destinationURL) { error in
            DispatchQueue.main.async {
                if let error {
                    _ = FileManager.deleteFile(at: destinationURL)
                    let alert = error.alertText
                    completion(.failure(AlertItem(title: alert.title, message: alert.message)))
                } else {
                    completion(.success(destinationURL))
                }
            }
        }
    }

    func updateQuickActions() {
        QuickActionCoordinator.shared.updateShortcutItems(allTunnelNames: tunnels.map(\.name))
    }

    func handleQuickAction(tunnelName: String) {
        guard let manager else {
            pendingQuickActionTunnelName = tunnelName
            return
        }
        guard let tunnel = manager.tunnel(named: tunnelName) else { return }
        requestedNavigationTunnelID = ObjectIdentifier(tunnel)

        let state = displayState(for: tunnel)
        if state.hasOnDemandRules {
            setTunnelActive(!state.isOnDemandEnabled, for: tunnel)
        } else if state.status == .inactive {
            setTunnelActive(true, for: tunnel)
        } else if state.status == .active {
            setTunnelActive(false, for: tunnel)
        }
    }

    func flushPendingQuickAction() {
        guard let pendingName = pendingQuickActionTunnelName else { return }
        pendingQuickActionTunnelName = nil
        handleQuickAction(tunnelName: pendingName)
    }

    func consumeRequestedNavigationTunnelID() -> ObjectIdentifier? {
        defer { requestedNavigationTunnelID = nil }
        return requestedNavigationTunnelID
    }
}
