// SPDX-License-Identifier: MIT

import Foundation
import Observation
import SplitGuardCore

@MainActor
protocol TunnelActivationObserver: AnyObject {
    func activationService(
        _ service: TunnelActivationService,
        didRecordActivationError error: TunnelError,
        forTunnelNamed name: String
    )
    func activationService(
        _ service: TunnelActivationService,
        didClearActivationErrorForTunnelNamed name: String
    )
    func activationService(_ service: TunnelActivationService, didEncounterControlError error: TunnelError)
    func activationService(_ service: TunnelActivationService, didFinishLoadWithIssues issues: Set<TunnelLoadIssue>)
    func activationService(_ service: TunnelActivationService, didRemoveTunnelWithID id: Tunnel.ID)
    func activationServiceDidUpdateTunnels(_ service: TunnelActivationService)
}

@MainActor
@Observable
final class TunnelActivationService {
    enum WaitTarget: Equatable {
        case active
        case inactive
    }

    enum WaitError: Error, Equatable {
        case tunnelError(TunnelError)
        case timedOut
    }

    final class Waiter {
        let id = UUID()
        let target: WaitTarget
        var result: Result<TunnelStatus, Error>?
        var continuation: CheckedContinuation<TunnelStatus, Error>?
        var timeoutTask: Task<Void, Never>?

        init(target: WaitTarget) {
            self.target = target
        }
    }

    static let shared: TunnelActivationService = {
        Log.configure(source: "APP", fileURL: AppGroup.appLogURL())
        return TunnelActivationService(
            backend: nil,
            snapshotStore: TunnelStatusSnapshotStore.shared(),
            updatesAppShortcuts: true
        )
    }()

    let backend: any TunnelBackend
    let snapshotStore: TunnelStatusSnapshotStore?
    let recentTunnelsUserDefaults: UserDefaults?
    let transitionPollInterval: Duration
    let defaultOperationTimeout: Duration
    let updatesAppShortcuts: Bool

    private(set) var tunnels: [Tunnel] = []
    private(set) var hasLoaded = false
    private(set) var revision = 0

    var attemptingActivationIDs: Set<Tunnel.ID> = []
    var restartingTunnelIDs: Set<Tunnel.ID> = []
    var waitingTunnelID: Tunnel.ID?
    var waiteeTunnelID: Tunnel.ID?
    var pendingDeactivationActions: [Tunnel.ID: @MainActor () async -> Void] = [:]
    var mutationEpoch = 0

    @ObservationIgnored weak var observer: (any TunnelActivationObserver)?
    @ObservationIgnored private var isReloadingFromBackend = false
    @ObservationIgnored private var needsAnotherReload = false
    @ObservationIgnored var statusWaiters: [Tunnel.ID: [Waiter]] = [:]
    @ObservationIgnored var activePollInterval: Duration?
    @ObservationIgnored private var lastShortcutsSignature: [(UUID, String)] = []
    @ObservationIgnored nonisolated(unsafe) var eventTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var transitionPollTask: Task<Void, Never>?

    init(
        backend: (any TunnelBackend)? = nil,
        snapshotStore: TunnelStatusSnapshotStore? = nil,
        recentTunnelsUserDefaults: UserDefaults? = nil,
        transitionPollInterval: Duration = .seconds(5),
        defaultOperationTimeout: Duration = .seconds(20),
        updatesAppShortcuts: Bool = false
    ) {
        #if DEBUG && targetEnvironment(simulator)
        self.backend = backend ?? (ScreenshotDemoData.isRequested ? ScreenshotDemoData.makeBackend() : InMemoryTunnelBackend())
        #elseif targetEnvironment(simulator)
        self.backend = backend ?? InMemoryTunnelBackend()
        #else
        self.backend = backend ?? SystemTunnelBackend()
        #endif
        self.snapshotStore = snapshotStore
        self.recentTunnelsUserDefaults = recentTunnelsUserDefaults
        self.transitionPollInterval = transitionPollInterval
        self.defaultOperationTimeout = defaultOperationTimeout
        self.updatesAppShortcuts = updatesAppShortcuts

        startEventStream()
    }

    deinit {
        eventTask?.cancel()
        transitionPollTask?.cancel()
    }

    var activeTunnel: Tunnel? {
        tunnels.first { $0.status != .inactive }
    }

    func tunnel(for id: Tunnel.ID) -> Tunnel? {
        tunnels.first { $0.id == id }
    }

    func tunnel(named name: String) -> Tunnel? {
        tunnels.first { $0.name == name }
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

    @discardableResult
    func loadSnapshot() async throws -> TunnelLoadSnapshot {
        let snapshot = try await backend.loadSnapshot()
        applyLoadSnapshot(snapshot)
        return snapshot
    }

    func ensureLoaded() async throws {
        if !hasLoaded {
            _ = try await loadSnapshot()
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
                let snapshot = try await backend.loadSnapshot()
                if mutationEpoch != startEpoch {
                    needsAnotherReload = true
                    continue
                }
                applyLoadSnapshot(snapshot)
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
                    || !(statusWaiters[id]?.isEmpty ?? true)
            )
            if status != tunnel.status || hasPendingTransition {
                await handleStatusChange(tunnelID: id, status: status)
            }
        }
        updateTransitionPolling()
    }

    @discardableResult
    func upsertTunnel(from record: TunnelRecord) -> Tunnel {
        if let existing = tunnel(for: record.id) {
            existing.apply(record: record)
            syncStatusSnapshot()
            return existing
        }
        let created = Tunnel(record: record)
        tunnels.append(created)
        syncStatusSnapshot()
        return created
    }

    func removeTunnelLocally(id: Tunnel.ID) {
        cleanupState(forRemovedID: id)
        tunnels.removeAll { $0.id == id }
        RecentTunnelsTracker.handleTunnelRemoved(
            tunnelID: id,
            userDefaults: recentTunnelsUserDefaults
        )
        syncStatusSnapshot()
        refreshShortcutsIfEnabled()
    }

    func sortTunnels() {
        tunnels.sort { Self.tunnelNameIsLessThan($0.name, $1.name) }
        syncStatusSnapshot()
    }

    func bumpRevision() {
        revision += 1
        refreshShortcutsIfEnabled()
    }

    func markLocalMutation() {
        mutationEpoch &+= 1
    }

    func syncStatusSnapshot() {
        guard let snapshotStore else { return }
        let now = Date()
        let entries = tunnels.map { tunnel in
            TunnelStatusSnapshot.Entry(
                id: tunnel.id,
                name: tunnel.name,
                status: tunnel.status.snapshotStatus,
                hasOnDemandRules: tunnel.hasOnDemandRules,
                isOnDemandEnabled: tunnel.isOnDemandEnabled,
                updatedAt: now
            )
        }
        snapshotStore.replaceAll(entries: entries, updatedAt: now)
    }

    func refreshShortcutsIfEnabled() {
        guard updatesAppShortcuts else { return }
        let signature = tunnels.map { ($0.id, $0.name) }
        guard signature.count != lastShortcutsSignature.count
            || zip(signature, lastShortcutsSignature).contains(where: { $0 != $1 }) else {
            return
        }
        lastShortcutsSignature = signature
        SplitGuardShortcuts.updateAppShortcutParameters()
    }
}

private extension TunnelActivationService {
    func startEventStream() {
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

    func applyLoadSnapshot(_ snapshot: TunnelLoadSnapshot) {
        applyLoadedRecords(snapshot.records, preservingIDs: Set(snapshot.issues.map(\.tunnelID)))
        hasLoaded = true
        RecentTunnelsTracker.cleanupTunnels(
            except: Set(tunnels.map(\.id)).union(snapshot.issues.map(\.tunnelID)),
            userDefaults: recentTunnelsUserDefaults
        )
        syncStatusSnapshot()
        refreshShortcutsIfEnabled()
        observer?.activationServiceDidUpdateTunnels(self)
        observer?.activationService(self, didFinishLoadWithIssues: snapshot.issues)
    }

    func applyLoadedRecords(_ records: [TunnelRecord], preservingIDs: Set<Tunnel.ID>) {
        let existingByID = Dictionary(tunnels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let loadedIDs = Set(records.map(\.id))

        let removedIDs = Set(existingByID.keys).subtracting(loadedIDs).subtracting(preservingIDs)
        for removedID in removedIDs {
            cleanupState(forRemovedID: removedID)
            observer?.activationService(self, didRemoveTunnelWithID: removedID)
        }

        var updatedTunnels = tunnels.filter { preservingIDs.contains($0.id) && !loadedIDs.contains($0.id) }

        for record in records {
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

        tunnels = updatedTunnels.sorted { Self.tunnelNameIsLessThan($0.name, $1.name) }
        revision += 1
        updateTransitionPolling()
    }
}
