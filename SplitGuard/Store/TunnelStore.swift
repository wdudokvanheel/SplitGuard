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
    private(set) var tunnels: [Tunnel] = []
    private(set) var isLoading = true
    private(set) var hasLoaded = false
    private(set) var revision = 0
    private(set) var lastActivationError: ActivationErrorBanner?

    var activeAlert: AlertItem?
    var requestedNavigationTunnelID: Tunnel.ID?
    var pendingSplitDNSSuggestion: SplitDNSSuggestionPrompt?
    private(set) var favoriteTunnelName: String?
    private(set) var appearanceMode: AppAppearanceMode

    var pendingOpenedURLs: [URL] = []
    var pendingQuickActionTunnelName: String?

    let backend: any TunnelBackend
    let recentTunnelsUserDefaults: UserDefaults?
    private let userDefaults: UserDefaults
    let transitionPollInterval: Duration
    private var alertQueue: [AlertItem] = []

    var attemptingActivationIDs: Set<Tunnel.ID> = []
    var restartingTunnelIDs: Set<Tunnel.ID> = []
    var waitingTunnelID: Tunnel.ID?
    var waiteeTunnelID: Tunnel.ID?
    var pendingDeactivationActions: [Tunnel.ID: @MainActor () async -> Void] = [:]
    var mutationEpoch = 0
    private var isReloadingFromBackend = false
    private var needsAnotherReload = false

    @ObservationIgnored nonisolated(unsafe) var eventTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var transitionPollTask: Task<Void, Never>?

    private static let favoriteTunnelDefaultsKey = "splitguard.favoriteTunnelName"

    init(
        backend: (any TunnelBackend)? = nil,
        autoLoad: Bool = true,
        userDefaults: UserDefaults = .standard,
        recentTunnelsUserDefaults: UserDefaults? = nil,
        transitionPollInterval: Duration = .seconds(5)
    ) {
        #if targetEnvironment(simulator)
        self.backend = backend ?? InMemoryTunnelBackend()
        #else
        self.backend = backend ?? SystemTunnelBackend()
        #endif
        self.userDefaults = userDefaults
        self.recentTunnelsUserDefaults = recentTunnelsUserDefaults
        self.transitionPollInterval = transitionPollInterval
        self.favoriteTunnelName = userDefaults.string(forKey: Self.favoriteTunnelDefaultsKey)
        self.appearanceMode = AppAppearanceMode.load(from: userDefaults)

        startEventStream()

        if autoLoad {
            Task { [weak self] in
                await self?.loadTunnels()
            }
        } else {
            isLoading = false
        }
    }

    deinit {
        eventTask?.cancel()
        transitionPollTask?.cancel()
    }

    func setAppearanceMode(_ mode: AppAppearanceMode) {
        guard appearanceMode != mode else { return }
        appearanceMode = mode
        mode.save(to: userDefaults)
    }

    var activeTunnel: Tunnel? {
        tunnels.first { $0.status != .inactive }
    }

    var favoriteTunnel: Tunnel? {
        guard let favoriteTunnelName else { return nil }
        return tunnels.first { $0.name == favoriteTunnelName }
    }

    var featuredTunnel: Tunnel? {
        activeTunnel ?? favoriteTunnel ?? tunnels.first
    }

    func isFavorite(_ tunnel: Tunnel) -> Bool {
        favoriteTunnelName == tunnel.name
    }

    func toggleFavorite(_ tunnel: Tunnel) {
        setFavoriteTunnelName(isFavorite(tunnel) ? nil : tunnel.name)
    }

    func setFavorite(_ tunnel: Tunnel?) {
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

    func tunnel(for id: Tunnel.ID) -> Tunnel? {
        tunnels.first { $0.id == id }
    }

    func tunnel(named name: String) -> Tunnel? {
        tunnels.first { $0.name == name }
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

    func setTunnelsList(_ newTunnels: [Tunnel]) {
        tunnels = newTunnels
    }

    func appendTunnel(_ tunnel: Tunnel) {
        tunnels.append(tunnel)
    }

    func removeTunnelFromList(id: Tunnel.ID) {
        tunnels.removeAll { $0.id == id }
    }

    func sortTunnels() {
        tunnels.sort { Self.tunnelNameIsLessThan($0.name, $1.name) }
    }

    func bumpRevision() {
        revision += 1
    }

    func setLoadingState(isLoading: Bool, hasLoaded: Bool? = nil) {
        self.isLoading = isLoading
        if let hasLoaded {
            self.hasLoaded = hasLoaded
        }
    }

    static func tunnelNameIsLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    func wrapError(_ error: Error, fallback: (String) -> TunnelError) -> TunnelError {
        if let tunnelError = error as? TunnelError {
            return tunnelError
        }
        return fallback(TunnelError.describeSystemError(error))
    }
}

extension TunnelStore {
    func loadTunnels() async {
        setLoadingState(isLoading: true)
        do {
            let records = try await backend.loadAll()
            applyLoadedRecords(records)
            setLoadingState(isLoading: false, hasLoaded: true)
            RecentTunnelsTracker.cleanupTunnels(
                except: Set(tunnels.map(\.name)),
                userDefaults: recentTunnelsUserDefaults
            )
            updateQuickActions()
            flushPendingQuickAction()
            await flushPendingOpenedURLs()
        } catch {
            setLoadingState(isLoading: false)
            present(error: wrapError(error, fallback: TunnelError.loadFailed))
        }
    }

    func reloadFromBackend() async {
        if isReloadingFromBackend {
            needsAnotherReload = true
            return
        }
        isReloadingFromBackend = true
        defer { isReloadingFromBackend = false }

        repeat {
            needsAnotherReload = false
            let startEpoch = mutationEpoch
            do {
                let records = try await backend.loadAll()
                if mutationEpoch != startEpoch {
                    needsAnotherReload = true
                    continue
                }
                applyLoadedRecords(records)
                setLoadingState(isLoading: false, hasLoaded: true)
                RecentTunnelsTracker.cleanupTunnels(
                    except: Set(tunnels.map(\.name)),
                    userDefaults: recentTunnelsUserDefaults
                )
                updateQuickActions()
            } catch {
                Log.error("Failed to reload tunnels after configuration change: \(error)")
            }
        } while needsAnotherReload
    }

    func refreshStatuses() async {
        let statuses = await backend.refreshStatuses()
        for (id, status) in statuses {
            guard let tunnel = tunnel(for: id) else { continue }
            if id == waitingTunnelID && status == .inactive {
                continue
            }
            let hasPendingTransition = status == .inactive && (
                attemptingActivationIDs.contains(id)
                    || restartingTunnelIDs.contains(id)
                    || pendingDeactivationActions[id] != nil
                    || waiteeTunnelID == id
            )
            if status != tunnel.status || hasPendingTransition {
                await handleStatusChange(tunnelID: id, status: status)
            }
        }
        updateTransitionPolling()
    }

    func fetchDeviceStatus(for tunnel: Tunnel) async -> DeviceStatus? {
        guard tunnel.status != .inactive else { return nil }
        return await backend.fetchDeviceStatus(for: tunnel.id)
    }

    private func startEventStream() {
        let stream = backend.events()
        eventTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .statusChanged(let tunnelID, let status):
                    await self.handleStatusChange(tunnelID: tunnelID, status: status)
                case .configurationsChanged:
                    await self.reloadFromBackend()
                }
            }
        }
    }

    func applyLoadedRecords(_ records: [TunnelRecord]) {
        let existingByID = Dictionary(tunnels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sortedRecords = records.sorted { Self.tunnelNameIsLessThan($0.profile.name, $1.profile.name) }
        let activeIDs = Set(sortedRecords.map(\.id))

        let removedIDs = Set(existingByID.keys).subtracting(activeIDs)
        for removedID in removedIDs {
            cleanupState(forRemovedID: removedID)
        }

        var updatedTunnels: [Tunnel] = []
        updatedTunnels.reserveCapacity(sortedRecords.count)

        for record in sortedRecords {
            if let existing = existingByID[record.id] {
                let preserveSyntheticStatus =
                    (restartingTunnelIDs.contains(record.id) && record.status != .inactive)
                    || (waitingTunnelID == record.id && record.status == .inactive)
                existing.apply(record: record, preservingStatus: preserveSyntheticStatus)
                updatedTunnels.append(existing)
            } else {
                updatedTunnels.append(Tunnel(record: record))
            }
        }

        setTunnelsList(updatedTunnels)
        bumpRevision()
        updateTransitionPolling()
    }

    func cleanupState(forRemovedID id: Tunnel.ID) {
        attemptingActivationIDs.remove(id)
        restartingTunnelIDs.remove(id)
        if waitingTunnelID == id {
            waitingTunnelID = nil
            waiteeTunnelID = nil
        }
        if waiteeTunnelID == id {
            waiteeTunnelID = nil
            if let nextID = waitingTunnelID, let nextTunnel = tunnel(for: nextID) {
                waitingTunnelID = nil
                nextTunnel.status = .inactive
            }
        }
        if let action = pendingDeactivationActions.removeValue(forKey: id) {
            Task { @MainActor in
                await action()
            }
        }
    }
}
