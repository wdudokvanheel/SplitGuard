// SPDX-License-Identifier: MIT

import Foundation
import Observation
import SplitGuardCore
import WireGuardEngine

struct AlertItem: Identifiable, Equatable, Error, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

struct ActivationErrorBanner: Identifiable, Equatable, Sendable {
    let id = UUID()
    let tunnelName: String
    let title: String
    let message: String
}

struct SplitDNSSuggestionPrompt: Identifiable, Equatable, Hashable, Sendable {
    let id = UUID()
    let tunnelID: Tunnel.ID
    let tunnelName: String
    let suggestedDomain: String
    let dnsServers: [String]
}

@MainActor
@Observable
final class TunnelStore {
    let activationService: TunnelActivationService
    let backend: any TunnelBackend

    private(set) var isLoading = true
    private(set) var lastActivationError: ActivationErrorBanner?

    var activeAlert: AlertItem?
    var requestedNavigationTunnelID: Tunnel.ID?
    var pendingSplitDNSSuggestion: SplitDNSSuggestionPrompt?
    private(set) var favoriteTunnelID: Tunnel.ID?
    private(set) var appearanceMode: AppAppearanceMode

    var pendingOpenedURLs: [URL] = []
    var pendingQuickActionTunnelID: Tunnel.ID?

    private let userDefaults: UserDefaults
    private var alertQueue: [AlertItem] = []
    @ObservationIgnored private var lastLoadIssues: Set<TunnelLoadIssue> = []

    private static let favoriteTunnelDefaultsKey = "splitguard.favoriteTunnelID"

    var tunnels: [Tunnel] {
        activationService.tunnels
    }

    var hasLoaded: Bool {
        activationService.hasLoaded
    }

    var revision: Int {
        activationService.revision
    }

    var recentTunnelsUserDefaults: UserDefaults? {
        activationService.recentTunnelsUserDefaults
    }

    var pendingDeactivationActions: [Tunnel.ID: @MainActor () async -> Void] {
        get { activationService.pendingDeactivationActions }
        set { activationService.pendingDeactivationActions = newValue }
    }

    init(
        activationService: TunnelActivationService? = nil,
        backend: (any TunnelBackend)? = nil,
        autoLoad: Bool = true,
        userDefaults: UserDefaults = .standard,
        recentTunnelsUserDefaults: UserDefaults? = nil,
        transitionPollInterval: Duration = .seconds(5)
    ) {
        if let activationService {
            self.activationService = activationService
        } else if let backend {
            self.activationService = TunnelActivationService(
                backend: backend,
                snapshotStore: nil,
                recentTunnelsUserDefaults: recentTunnelsUserDefaults,
                transitionPollInterval: transitionPollInterval
            )
        } else {
            self.activationService = TunnelActivationService.shared
        }
        self.backend = self.activationService.backend
        self.userDefaults = userDefaults
        self.favoriteTunnelID = userDefaults.string(forKey: Self.favoriteTunnelDefaultsKey).flatMap(UUID.init(uuidString:))
        self.appearanceMode = AppAppearanceMode.load(from: userDefaults)

        self.activationService.observer = self

        if autoLoad {
            Task { [weak self] in
                await self?.loadTunnels()
            }
        } else {
            isLoading = false
        }
    }

    func setAppearanceMode(_ mode: AppAppearanceMode) {
        guard appearanceMode != mode else { return }
        appearanceMode = mode
        mode.save(to: userDefaults)
    }

    var activeTunnel: Tunnel? {
        activationService.activeTunnel
    }

    var favoriteTunnel: Tunnel? {
        favoriteTunnelID.flatMap(tunnel(for:))
    }

    var featuredTunnel: Tunnel? {
        activeTunnel ?? favoriteTunnel ?? tunnels.first
    }

    func isFavorite(_ tunnel: Tunnel) -> Bool {
        favoriteTunnelID == tunnel.id
    }

    func toggleFavorite(_ tunnel: Tunnel) {
        setFavorite(isFavorite(tunnel) ? nil : tunnel)
    }

    func setFavorite(_ tunnel: Tunnel?) {
        favoriteTunnelID = tunnel?.id
        if let id = tunnel?.id {
            userDefaults.set(id.uuidString, forKey: Self.favoriteTunnelDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: Self.favoriteTunnelDefaultsKey)
        }
    }

    func tunnel(for id: Tunnel.ID) -> Tunnel? {
        activationService.tunnel(for: id)
    }

    func tunnel(named name: String) -> Tunnel? {
        activationService.tunnel(named: name)
    }

    func status(for tunnel: Tunnel) -> TunnelStatus {
        tunnel.status
    }

    func isOnDemandEnabled(for tunnel: Tunnel) -> Bool {
        tunnel.isOnDemandEnabled
    }

    func hasOnDemandRules(for tunnel: Tunnel) -> Bool {
        tunnel.hasOnDemandRules
    }

    func displayState(
        for tunnel: Tunnel,
        killSwitchBlockState: KillSwitchBlockState? = nil
    ) -> TunnelDisplayState {
        TunnelDisplayState(
            status: tunnel.status,
            hasOnDemandRules: tunnel.hasOnDemandRules,
            isOnDemandEnabled: tunnel.isOnDemandEnabled,
            killSwitchBlockState: killSwitchBlockState
        )
    }

    func recordActivationError(tunnelName: String, error: TunnelError) {
        recordActivationError(tunnelName: tunnelName, title: error.title, message: error.message)
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

    func present(error: TunnelError) {
        presentAlert(title: error.title, message: error.message)
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

    func sortTunnels() {
        activationService.sortTunnels()
    }

    func bumpRevision() {
        activationService.bumpRevision()
    }

    static func tunnelNameIsLessThan(_ lhs: String, _ rhs: String) -> Bool {
        TunnelActivationService.tunnelNameIsLessThan(lhs, rhs)
    }

    func wrapError(_ error: Error, fallback: (String) -> TunnelError) -> TunnelError {
        activationService.wrapError(error, fallback: fallback)
    }
}

extension TunnelStore {
    func loadTunnels() async {
        isLoading = true
        do {
            _ = try await activationService.loadSnapshot()
            isLoading = false
            flushPendingQuickAction()
            await flushPendingOpenedURLs()
        } catch {
            isLoading = false
            present(error: wrapError(error, fallback: TunnelError.loadFailed))
        }
    }

    func reloadFromBackend() async {
        await activationService.reloadFromBackend()
    }

    func refreshStatuses() async {
        await activationService.refreshStatuses()
    }

    func fetchDeviceStatus(for tunnel: Tunnel) async -> DeviceStatus? {
        guard tunnel.status != .inactive else { return nil }
        return await backend.fetchDeviceStatus(for: tunnel.id)
    }
}

extension TunnelStore: TunnelActivationObserver {
    func activationService(
        _ service: TunnelActivationService,
        didRecordActivationError error: TunnelError,
        forTunnelNamed name: String
    ) {
        recordActivationError(tunnelName: name, error: error)
    }

    func activationService(
        _ service: TunnelActivationService,
        didClearActivationErrorForTunnelNamed name: String
    ) {
        clearActivationError(for: name)
    }

    func activationService(_ service: TunnelActivationService, didEncounterControlError error: TunnelError) {
        present(error: error)
    }

    func activationService(_ service: TunnelActivationService, didFinishLoadWithIssues issues: Set<TunnelLoadIssue>) {
        isLoading = false
        let newIssues = issues.subtracting(lastLoadIssues)
        lastLoadIssues = issues
        guard !newIssues.isEmpty else { return }

        let messages = newIssues.map(\.message).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        presentAlert(title: "Some tunnels could not be loaded", message: messages.joined(separator: "\n\n"))
    }

    func activationService(_ service: TunnelActivationService, didRemoveTunnelWithID id: Tunnel.ID) {
        if favoriteTunnelID == id {
            setFavorite(nil)
        }
    }

    func activationServiceDidUpdateTunnels(_ service: TunnelActivationService) {
        updateQuickActions()
    }
}
