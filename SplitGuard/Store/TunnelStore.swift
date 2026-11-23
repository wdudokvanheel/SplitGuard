import Foundation
import Observation
import WireGuardKit

struct AlertItem: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

struct ActivationErrorBanner: Identifiable, Equatable {
    let id = UUID()
    let tunnelName: String
    let title: String
    let message: String
}

final class SwiftUIErrorPresenter: ErrorPresenterProtocol {
    static func showErrorAlert(
        title: String,
        message: String,
        from sourceVC: AnyObject?,
        onPresented: (() -> Void)?,
        onDismissal: (() -> Void)?
    ) {
        DispatchQueue.main.async {
            if let store = sourceVC as? TunnelStore {
                store.presentAlert(title: title, message: message)
            }
            onPresented?()
            onDismissal?()
        }
    }
}

@MainActor
@Observable
final class TunnelStore {
    private(set) var tunnels: [TunnelContainer] = []
    private(set) var isLoading = true
    private(set) var revision = 0
    private(set) var lastActivationError: ActivationErrorBanner?

    private(set) var statusByTunnel: [ObjectIdentifier: TunnelStatus] = [:]
    private(set) var onDemandEnabledByTunnel: [ObjectIdentifier: Bool] = [:]
    private(set) var hasOnDemandRulesByTunnel: [ObjectIdentifier: Bool] = [:]

    var activeAlert: AlertItem?

    var manager: TunnelsManager?
    var pendingOpenedURLs: [URL] = []
    private var alertQueue: [AlertItem] = []
    private var observations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]

    init(autoLoad: Bool = true) {
        if autoLoad {
            loadTunnels()
        }
    }

    var backendVersion: String {
        WIREGUARD_GO_VERSION
    }

    var activeTunnel: TunnelContainer? {
        tunnels.first { status(for: $0) != .inactive }
    }

    func loadTunnels() {
        isLoading = true
        TunnelsManager.create { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let manager):
                    self.attach(manager: manager)
                case .failure(let error):
                    self.present(error: error)
                }
            }
        }
    }

    func attach(manager: TunnelsManager) {
        self.manager = manager
        manager.tunnelsListDelegate = self
        manager.activationDelegate = self
        isLoading = false
        syncTunnelsFromManager()
        flushPendingOpenedURLs()
    }

    func tunnel(for id: ObjectIdentifier) -> TunnelContainer? {
        tunnels.first { ObjectIdentifier($0) == id }
    }

    func status(for tunnel: TunnelContainer) -> TunnelStatus {
        statusByTunnel[ObjectIdentifier(tunnel)] ?? tunnel.status
    }

    func isOnDemandEnabled(for tunnel: TunnelContainer) -> Bool {
        onDemandEnabledByTunnel[ObjectIdentifier(tunnel)] ?? tunnel.isActivateOnDemandEnabled
    }

    func hasOnDemandRules(for tunnel: TunnelContainer) -> Bool {
        hasOnDemandRulesByTunnel[ObjectIdentifier(tunnel)] ?? tunnel.hasOnDemandRules
    }

    func displayState(for tunnel: TunnelContainer) -> TunnelDisplayState {
        TunnelDisplayState(
            status: status(for: tunnel),
            hasOnDemandRules: hasOnDemandRules(for: tunnel),
            isOnDemandEnabled: isOnDemandEnabled(for: tunnel)
        )
    }

    func refreshStatuses() {
        manager?.refreshStatuses()
    }

    func setTunnelActive(_ isOn: Bool, for tunnel: TunnelContainer) {
        guard let manager else { return }
        clearActivationError(for: tunnel.name)

        if hasOnDemandRules(for: tunnel) {
            manager.setOnDemandEnabled(isOn, on: tunnel) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.present(error: error)
                        return
                    }
                    if !isOn {
                        manager.startDeactivation(of: tunnel)
                    }
                }
            }
        } else if isOn {
            manager.startActivation(of: tunnel)
        } else {
            manager.startDeactivation(of: tunnel)
        }
    }

    func delete(tunnel: TunnelContainer, completion: ((Bool) -> Void)? = nil) {
        guard let manager else {
            completion?(false)
            return
        }
        manager.remove(tunnel: tunnel) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.present(error: error)
                    completion?(false)
                } else {
                    self.clearActivationError(for: tunnel.name)
                    self.syncTunnelsFromManager()
                    completion?(true)
                }
            }
        }
    }

    func recordActivationError(tunnelName: String, title: String, message: String) {
        lastActivationError = ActivationErrorBanner(
            tunnelName: tunnelName,
            title: title,
            message: message
        )
        presentAlert(title: title, message: message)
    }

    func clearActivationError(for tunnelName: String) {
        if lastActivationError?.tunnelName == tunnelName {
            lastActivationError = nil
        }
    }

    func dismissActivationErrorBanner() {
        lastActivationError = nil
    }

    func present(error: WireGuardAppError) {
        let alert = error.alertText
        presentAlert(title: alert.title, message: alert.message)
    }

    func presentAlert(title: String, message: String) {
        let item = AlertItem(title: title, message: message)
        if activeAlert == nil {
            activeAlert = item
        } else {
            alertQueue.append(item)
        }
    }

    func dismissActiveAlert() {
        activeAlert = alertQueue.isEmpty ? nil : alertQueue.removeFirst()
    }

    func syncTunnelsFromManager() {
        guard let manager else { return }
        let list = manager.mapTunnels { $0 }
        tunnels = list
        revision += 1

        let activeIDs = Set(list.map(ObjectIdentifier.init))
        observations = observations.filter { activeIDs.contains($0.key) }
        statusByTunnel = statusByTunnel.filter { activeIDs.contains($0.key) }
        onDemandEnabledByTunnel = onDemandEnabledByTunnel.filter { activeIDs.contains($0.key) }
        hasOnDemandRulesByTunnel = hasOnDemandRulesByTunnel.filter { activeIDs.contains($0.key) }

        for tunnel in list {
            let id = ObjectIdentifier(tunnel)
            statusByTunnel[id] = tunnel.status
            onDemandEnabledByTunnel[id] = tunnel.isActivateOnDemandEnabled
            hasOnDemandRulesByTunnel[id] = tunnel.hasOnDemandRules
            installObserversIfNeeded(for: tunnel, id: id)
        }
    }

    private func installObserversIfNeeded(for tunnel: TunnelContainer, id: ObjectIdentifier) {
        guard observations[id] == nil else { return }
        let statusObs = tunnel.observe(\.status, options: [.new]) { [weak self] container, _ in
            let newStatus = container.status
            Task { @MainActor [weak self] in
                self?.statusByTunnel[ObjectIdentifier(container)] = newStatus
            }
        }
        let onDemandObs = tunnel.observe(\.isActivateOnDemandEnabled, options: [.new]) { [weak self] container, _ in
            let newValue = container.isActivateOnDemandEnabled
            Task { @MainActor [weak self] in
                self?.onDemandEnabledByTunnel[ObjectIdentifier(container)] = newValue
            }
        }
        let rulesObs = tunnel.observe(\.hasOnDemandRules, options: [.new]) { [weak self] container, _ in
            let newValue = container.hasOnDemandRules
            Task { @MainActor [weak self] in
                self?.hasOnDemandRulesByTunnel[ObjectIdentifier(container)] = newValue
            }
        }
        observations[id] = [statusObs, onDemandObs, rulesObs]
    }
}
