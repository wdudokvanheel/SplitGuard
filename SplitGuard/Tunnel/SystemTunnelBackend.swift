// SPDX-License-Identifier: MIT

import Foundation
import NetworkExtension
import SplitGuardCore
import WireGuardEngine

actor SystemTunnelBackend: TunnelBackend {
    static let maxStartAttempts = 8

    private final class ObserverBag: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [NSObjectProtocol] = []

        func add(_ token: NSObjectProtocol) {
            lock.withLock {
                tokens.append(token)
            }
        }

        deinit {
            let currentTokens = lock.withLock { tokens }
            for token in currentTokens {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    let profileStore: ProfileStore
    let providerBundleIdentifier: String
    let loadPreferenceManagers: @Sendable () async throws -> [NETunnelProviderManager]
    let eventHub = BackendEventHub()
    private let observerBag = ObserverBag()

    var managersByID: [UUID: NETunnelProviderManager] = [:]
    var idByPasswordReference: [Data: UUID] = [:]
    var idByObjectID: [ObjectIdentifier: UUID] = [:]
    private var pendingKeychainReferences: Set<Data> = []
    var isPreferenceOperationActive = false
    var preferenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var isObservingNotifications = false
    private var configurationChangeObservationPaused = false

    nonisolated var saveNewDeactivatesActiveTunnel: Bool { true }

    init(
        profileStore: ProfileStore = ProfileStore(),
        bundle: Bundle = .main,
        loadPreferenceManagers: @escaping @Sendable () async throws -> [NETunnelProviderManager] =
            { try await NETunnelProviderManager.loadAllFromPreferences() }
    ) {
        self.profileStore = profileStore
        self.loadPreferenceManagers = loadPreferenceManagers
        let baseIdentifier = bundle.bundleIdentifier ?? "com.bitechular.splitguard"
        self.providerBundleIdentifier = baseIdentifier + ".network-extension"
    }

    deinit {
        eventHub.finish()
    }

    nonisolated func events() -> AsyncStream<BackendEvent> {
        let stream = eventHub.stream()
        Task { [weak self] in
            await self?.installNotificationObserversIfNeeded()
        }
        return stream
    }

    func setConfigurationChangeObservationPaused(_ paused: Bool) async {
        configurationChangeObservationPaused = paused
        if paused {
            await withSerializedPreferences {}
        }
    }

    func save(
        _ profile: TunnelProfile,
        onDemandPolicy: OnDemandPolicy,
        isOnDemandEnabled: Bool,
        localSettings: TunnelLocalSettings,
        replacing id: UUID?
    ) async throws -> TunnelRecord {
        try await withSerializedPreferences {
            try await performSave(
                profile,
                onDemandPolicy: onDemandPolicy,
                isOnDemandEnabled: isOnDemandEnabled,
                localSettings: localSettings,
                replacing: id
            )
        }
    }

    private func performSave(
        _ profile: TunnelProfile,
        onDemandPolicy: OnDemandPolicy,
        isOnDemandEnabled: Bool,
        localSettings: TunnelLocalSettings,
        replacing id: UUID?
    ) async throws -> TunnelRecord {
        installNotificationObserversIfNeeded()

        let manager = try resolveManagerForSave(replacing: id)
        let normalizedPolicy = onDemandPolicy.normalized()
        let effectiveOnDemand = normalizedPolicy.hasRules && isOnDemandEnabled
        let shouldReloadForOnDemand = needsReloadAfterOnDemandChange(
            manager: manager,
            newPolicy: normalizedPolicy,
            effectiveOnDemand: effectiveOnDemand
        )

        let oldReference = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference
        let newReference = try saveProfileToKeychain(profile)
        pendingKeychainReferences.insert(newReference)
        defer { pendingKeychainReferences.remove(newReference) }

        let tunnelID = id ?? UUID()
        configure(
            manager: manager,
            with: ManagerConfiguration(
                tunnelID: tunnelID,
                profile: profile,
                passwordReference: newReference,
                onDemandPolicy: normalizedPolicy,
                isOnDemandEnabled: effectiveOnDemand,
                localSettings: localSettings
            )
        )
        try await commitManagerPreferences(
            manager,
            newReference: newReference,
            oldReference: oldReference,
            shouldReloadForOnDemand: shouldReloadForOnDemand
        )

        managersByID[tunnelID] = manager
        idByPasswordReference[newReference] = tunnelID
        idByObjectID[ObjectIdentifier(manager)] = tunnelID

        return makeRecord(id: tunnelID, profile: profile, manager: manager)
    }

    func setOnDemandEnabled(_ isEnabled: Bool, for id: UUID) async throws -> TunnelRecord {
        try await withSerializedPreferences {
            try await performSetOnDemandEnabled(isEnabled, for: id)
        }
    }

    private func performSetOnDemandEnabled(_ isEnabled: Bool, for id: UUID) async throws -> TunnelRecord {
        guard let manager = managersByID[id] else {
            throw TunnelError.tunnelNotFound
        }

        let policy = OnDemandPolicy(from: manager.onDemandRules)
        let effectiveEnabled = policy.hasRules && isEnabled
        let isCurrentlyEnabled = manager.isOnDemandEnabled && manager.isEnabled

        if isCurrentlyEnabled != effectiveEnabled {
            let isActivatingOnDemand = !manager.isOnDemandEnabled && effectiveEnabled
            manager.isOnDemandEnabled = effectiveEnabled
            manager.isEnabled = true
            persistTunnelIDIfNeeded(id, on: manager)

            do {
                try await manager.saveToPreferences()
            } catch {
                Log.error("Modify On-Demand: Saving configuration failed: \(error)")
                throw TunnelError.saveFailed(TunnelError.describeSystemError(error))
            }

            if isActivatingOnDemand {
                // Quirk #3: Reload manager after enabling on-demand so status updates keep arriving.
                do {
                    try await manager.loadFromPreferences()
                } catch {
                    Log.error("Modify On-Demand: Reloading configuration failed: \(error)")
                    throw TunnelError.saveFailed(TunnelError.describeSystemError(error))
                }
            }
        }

        let profile = try loadCurrentProfile(for: manager)
        return makeRecord(id: id, profile: profile, manager: manager)
    }

    func remove(id: UUID) async throws {
        try await withSerializedPreferences {
            try await performRemove(id: id)
        }
    }

    private func performRemove(id: UUID) async throws {
        guard let manager = managersByID[id] else {
            throw TunnelError.tunnelNotFound
        }
        let oldReference = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference

        do {
            try await manager.removeFromPreferences()
        } catch {
            Log.error("Remove: Removing configuration failed: \(error)")
            throw TunnelError.removeFailed(TunnelError.describeSystemError(error))
        }

        if let oldReference {
            profileStore.delete(reference: oldReference)
            idByPasswordReference.removeValue(forKey: oldReference)
        }
        managersByID.removeValue(forKey: id)
        idByObjectID.removeValue(forKey: ObjectIdentifier(manager))
    }

    func installNotificationObserversIfNeeded() {
        guard !isObservingNotifications else { return }
        isObservingNotifications = true

        let statusToken = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let session = notification.object as? NETunnelProviderSession,
                  let manager = session.manager as? NETunnelProviderManager else {
                return
            }
            let objID = ObjectIdentifier(manager)
            let passwordRef = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference
            let status = TunnelStatus(from: session.status)
            Task { [weak self] in
                await self?.handleVPNStatusChange(objectID: objID, passwordReference: passwordRef, status: status)
            }
        }

        let configToken = NotificationCenter.default.addObserver(
            forName: .NEVPNConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handleConfigurationChange()
            }
        }

        observerBag.add(statusToken)
        observerBag.add(configToken)
    }

    private func handleVPNStatusChange(
        objectID: ObjectIdentifier,
        passwordReference: Data?,
        status: TunnelStatus
    ) {
        let tunnelID = idByObjectID[objectID]
            ?? passwordReference.flatMap { idByPasswordReference[$0] }
        guard let tunnelID else { return }
        eventHub.yield(.statusChanged(tunnelID: tunnelID, status: status))
    }

    private func handleConfigurationChange() {
        guard !configurationChangeObservationPaused else { return }
        eventHub.yield(.configurationsChanged)
    }
}

extension SystemTunnelBackend {
    func loadAll() async throws -> [TunnelRecord] {
        try await loadSnapshot().records
    }

    func loadSnapshot() async throws -> TunnelLoadSnapshot {
        try await withSerializedPreferences {
            try await performLoadAll()
        }
    }

    private func performLoadAll() async throws -> TunnelLoadSnapshot {
        installNotificationObserversIfNeeded()
        let managers = try await loadManagersFromPreferences()
        // NetworkExtension returns managers created by this app. Protect all their references before decoding profiles.
        let referencedManagers = managers.map { (manager: $0, reference: $0.protocolConfiguration?.passwordReference) }
        let activeReferences = Set(referencedManagers.compactMap(\.reference))

        var nextManagersByID: [UUID: NETunnelProviderManager] = [:]
        var nextIDByRef: [Data: UUID] = [:]
        var nextIDByObjID: [ObjectIdentifier: UUID] = [:]
        var claimedIDs: Set<UUID> = []
        var snapshot = TunnelLoadSnapshot()

        for (manager, passwordRef) in referencedManagers {
            let name = manager.localizedDescription ?? ""
            let profile = loadStoredProfile(reference: passwordRef, name: name)
            let id = resolveStableID(for: manager, passwordReference: passwordRef, claimedIDs: &claimedIDs)
            nextManagersByID[id] = manager
            if let passwordRef {
                nextIDByRef[passwordRef] = id
            }
            nextIDByObjID[ObjectIdentifier(manager)] = id
            switch profile {
            case .success(let profile):
                snapshot.records.append(makeRecord(id: id, profile: profile, manager: manager))
            case .failure(let reason):
                snapshot.issues.insert(TunnelLoadIssue(tunnelID: id, tunnelName: name, reason: reason))
            }
        }

        if !configurationChangeObservationPaused {
            profileStore.deleteOrphaned(keeping: activeReferences.union(pendingKeychainReferences))
        }
        managersByID = nextManagersByID
        idByPasswordReference = nextIDByRef
        idByObjectID = nextIDByObjID

        snapshot.records.sort { $0.profile.name.localizedStandardCompare($1.profile.name) == .orderedAscending }
        return snapshot
    }
}
