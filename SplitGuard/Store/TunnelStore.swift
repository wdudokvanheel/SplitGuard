import Foundation
import Observation
import WireGuardKit

struct AlertItem: Identifiable, Equatable, Error {
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

struct SplitDNSSuggestionPrompt: Identifiable, Equatable, Hashable {
    let id = UUID()
    let tunnelID: ObjectIdentifier
    let tunnelName: String
    let suggestedDomain: String
    let dnsServers: [String]
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
    var requestedNavigationTunnelID: ObjectIdentifier?
    var pendingSplitDNSSuggestion: SplitDNSSuggestionPrompt?
    private(set) var favoriteTunnelName: String?

    var manager: TunnelsManager?
    var pendingOpenedURLs: [URL] = []
    var pendingQuickActionTunnelName: String?
    private let userDefaults: UserDefaults
    private var alertQueue: [AlertItem] = []
    private var observations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]

    private static let favoriteTunnelDefaultsKey = "splitguard.favoriteTunnelName"

    init(autoLoad: Bool = true, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.favoriteTunnelName = userDefaults.string(forKey: Self.favoriteTunnelDefaultsKey)
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

    var favoriteTunnel: TunnelContainer? {
        guard let favoriteTunnelName else { return nil }
        return tunnels.first { $0.name == favoriteTunnelName }
    }

    var featuredTunnel: TunnelContainer? {
        activeTunnel ?? favoriteTunnel ?? tunnels.first
    }

    func isFavorite(_ tunnel: TunnelContainer) -> Bool {
        favoriteTunnelName == tunnel.name
    }

    func toggleFavorite(_ tunnel: TunnelContainer) {
        if isFavorite(tunnel) {
            setFavoriteTunnelName(nil)
        } else {
            setFavoriteTunnelName(tunnel.name)
        }
    }

    func setFavorite(_ tunnel: TunnelContainer?) {
        setFavoriteTunnelName(tunnel?.name)
    }

    private func setFavoriteTunnelName(_ name: String?) {
        favoriteTunnelName = name
        if let name {
            userDefaults.set(name, forKey: Self.favoriteTunnelDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: Self.favoriteTunnelDefaultsKey)
        }
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
        flushPendingQuickAction()
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
            statusByTunnel[ObjectIdentifier(tunnel)] = tunnel.status
        } else {
            manager.startDeactivation(of: tunnel)
            statusByTunnel[ObjectIdentifier(tunnel)] = tunnel.status
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
            hasOnDemandRulesByTunnel[id] = tunnel.hasOnDemandRules || tunnel.onDemandOption != .off
            installObserversIfNeeded(for: tunnel, id: id)
        }
        updateQuickActions()
    }

    private func installObserversIfNeeded(for tunnel: TunnelContainer, id: ObjectIdentifier) {
        guard observations[id] == nil else { return }
        let statusObs = tunnel.observe(\.status, options: [.new]) { [weak self] container, _ in
            let newStatus = container.status
            let containerID = ObjectIdentifier(container)
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.statusByTunnel[containerID] = newStatus
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.statusByTunnel[containerID] = newStatus
                }
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
