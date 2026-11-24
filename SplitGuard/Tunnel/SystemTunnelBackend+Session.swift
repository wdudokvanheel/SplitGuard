// SPDX-License-Identifier: MIT

import Foundation
import NetworkExtension
import Security
import SplitGuardCore
import WireGuardEngine

extension SystemTunnelBackend {
    func start(id: UUID) async throws {
        try await withSerializedPreferences {
            try await performStart(id: id)
        }
    }

    private func performStart(id: UUID) async throws {
        guard let manager = managersByID[id] else {
            throw TunnelError.tunnelNotFound
        }

        // Quirk #4: Re-enable if disabled; reload and retry up to 8 times on configurationInvalid/Stale.
        var lastError: Error?
        for attempt in 0 ..< Self.maxStartAttempts {
            if !manager.isEnabled {
                try await reenableDisabledManager(manager, attempt: attempt)
                lastError = NEVPNError(.configurationUnknown)
                continue
            }

            do {
                guard let session = manager.connection as? NETunnelProviderSession else {
                    throw TunnelError.activationAttemptFailed("Unable to obtain tunnel provider session.")
                }
                try session.startTunnel(options: ["startedByApp": NSNumber(value: true)])
                Log.debug("start: startTunnel succeeded for '\(manager.localizedDescription ?? "")'")
                return
            } catch let error as TunnelError {
                throw error
            } catch let vpnError as NEVPNError
                where vpnError.code == .configurationInvalid || vpnError.code == .configurationStale {
                Log.debug("start: Reloading tunnel after NEVPNError(\(vpnError.code.rawValue)) (attempt \(attempt + 1))")
                lastError = vpnError
                do {
                    try await manager.loadFromPreferences()
                } catch {
                    Log.error("start: Failed to reload tunnel preferences: \(error)")
                    throw TunnelError.activationAttemptFailed(TunnelError.describeSystemError(vpnError))
                }
            } catch {
                Log.error("start: Failed to start tunnel: \(error)")
                throw TunnelError.activationAttemptFailed(TunnelError.describeSystemError(error))
            }
        }

        let detail = lastError.map(TunnelError.describeSystemError) ?? "Exceeded maximum activation retry attempts."
        throw TunnelError.activationAttemptFailed(detail)
    }

    func stop(id: UUID) async {
        guard let manager = managersByID[id] else { return }
        Log.debug("stop: Stopping tunnel '\(manager.localizedDescription ?? "")'")
        (manager.connection as? NETunnelProviderSession)?.stopTunnel()
    }

    func fetchLastStartError(for id: UUID) async -> TunnelStartError? {
        guard let manager = managersByID[id] else { return nil }

        if let disconnectError = await fetchDisconnectError(from: manager.connection),
           let decoded = TunnelStartError(nsError: disconnectError as NSError) {
            return decoded
        }

        if case .lastStartError(let startError) = await sendProviderMessage(.lastStartError, to: id) {
            return startError
        }
        return nil
    }

    func fetchDeviceStatus(for id: UUID) async -> DeviceStatus? {
        guard let manager = managersByID[id],
              TunnelStatus(from: manager.connection.status) != .inactive else {
            return nil
        }
        if case .status(let deviceStatus) = await sendProviderMessage(.status, to: id) {
            return deviceStatus
        }
        return nil
    }

    func sendProviderMessage(_ message: ProviderMessage, to id: UUID) async -> ProviderReply? {
        guard let manager = managersByID[id],
              let session = manager.connection as? NETunnelProviderSession,
              let payload = try? message.encode() else {
            return nil
        }

        let responseData: Data? = await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(payload) { data in
                    continuation.resume(returning: data)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }

        guard let responseData else { return nil }
        return try? ProviderReply.decode(from: responseData)
    }

    func refreshStatuses() async -> [UUID: TunnelStatus] {
        var result: [UUID: TunnelStatus] = [:]
        for (id, manager) in managersByID {
            result[id] = TunnelStatus(from: manager.connection.status)
        }
        return result
    }

    private func reenableDisabledManager(_ manager: NETunnelProviderManager, attempt: Int) async throws {
        Log.debug("start: Re-enabling disabled tunnel '\(manager.localizedDescription ?? "")' (attempt \(attempt + 1))")
        manager.isEnabled = true
        do {
            try await manager.saveToPreferences()
        } catch {
            Log.error("start: Failed to save tunnel after re-enabling: \(error)")
            throw TunnelError.activationAttemptFailed(TunnelError.describeSystemError(error))
        }
    }

    private func fetchDisconnectError(from connection: NEVPNConnection) async -> Error? {
        await withCheckedContinuation { continuation in
            connection.fetchLastDisconnectError { error in
                continuation.resume(returning: error)
            }
        }
    }

    func loadCurrentProfile(for manager: NETunnelProviderManager) throws -> TunnelProfile {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            throw TunnelError.loadFailed("Tunnel protocol configuration is missing.")
        }
        do {
            return try profileStore.loadProfile(from: proto, name: manager.localizedDescription ?? "")
        } catch {
            throw TunnelError.loadFailed(TunnelError.describeSystemError(error))
        }
    }

    func makeRecord(id: UUID, profile: TunnelProfile, manager: NETunnelProviderManager) -> TunnelRecord {
        TunnelRecord(
            id: id,
            profile: profile,
            status: TunnelStatus(from: manager.connection.status),
            onDemandPolicy: OnDemandPolicy(from: manager.onDemandRules),
            isOnDemandEnabled: manager.isOnDemandEnabled && manager.isEnabled
        )
    }

    func withSerializedPreferences<T: Sendable>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        await acquirePreferenceLock()
        defer { releasePreferenceLock() }
        return try await operation()
    }

    private func acquirePreferenceLock() async {
        if !isPreferenceOperationActive {
            isPreferenceOperationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            preferenceWaiters.append(continuation)
        }
    }

    private func releasePreferenceLock() {
        if !preferenceWaiters.isEmpty {
            let next = preferenceWaiters.removeFirst()
            next.resume()
        } else {
            isPreferenceOperationActive = false
        }
    }

    func loadManagersFromPreferences() async throws -> [NETunnelProviderManager] {
        do {
            return try await loadPreferenceManagers()
        } catch {
            Log.error("Failed to load tunnel provider managers: \(error)")
            throw TunnelError.loadFailed(TunnelError.describeSystemError(error))
        }
    }

    func loadStoredProfile(reference: Data?, name: String) -> Result<TunnelProfile, TunnelLoadIssue.Reason> {
        guard let reference else {
            Log.warning("Unable to load tunnel '\(name)': Missing Keychain reference.")
            return .failure(.missingReference)
        }
        do {
            return .success(try profileStore.load(reference: reference, name: name))
        } catch ProfileStoreError.keychainLoadFailed(errSecItemNotFound) {
            Log.warning("Unable to load tunnel '\(name)': Keychain item is missing.")
            return .failure(.missingItem)
        } catch ProfileStoreError.keychainLoadFailed(let status) {
            Log.error("Unable to load tunnel '\(name)': Keychain read failed (OSStatus \(status)).")
            return .failure(.keychainUnavailable)
        } catch {
            // A parser error can contain parts of the stored configuration.
            Log.error("Unable to load tunnel '\(name)': Stored profile could not be decoded.")
            return .failure(.invalidProfile)
        }
    }

    func resolveManagerForSave(replacing id: UUID?) throws -> NETunnelProviderManager {
        guard let id else { return NETunnelProviderManager() }
        guard let existing = managersByID[id] else { throw TunnelError.tunnelNotFound }
        return existing
    }

    func needsReloadAfterOnDemandChange(
        manager: NETunnelProviderManager,
        newPolicy: OnDemandPolicy,
        effectiveOnDemand: Bool
    ) -> Bool {
        let wasEnabled = manager.isOnDemandEnabled
        let previousPolicy = OnDemandPolicy(from: manager.onDemandRules)
        return (effectiveOnDemand && !wasEnabled) || (effectiveOnDemand && newPolicy != previousPolicy)
    }

    func saveProfileToKeychain(_ profile: TunnelProfile) throws -> Data {
        do {
            return try profileStore.save(profile, replacing: nil)
        } catch {
            Log.error("Save: Failed to save profile to keychain: \(error)")
            throw TunnelError.saveFailed(TunnelError.describeSystemError(error))
        }
    }

    func configure(
        manager: NETunnelProviderManager,
        profile: TunnelProfile,
        passwordReference: Data,
        onDemandPolicy: OnDemandPolicy,
        isOnDemandEnabled: Bool
    ) {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.passwordReference = passwordReference
        proto.providerConfiguration = nil
        proto.serverAddress = ProfileStore.serverAddress(for: profile)
        proto.applyKillSwitch(profile.options.sanitized(for: profile))

        manager.localizedDescription = profile.name
        manager.protocolConfiguration = proto
        manager.isEnabled = true
        onDemandPolicy.apply(to: manager)
        manager.isOnDemandEnabled = isOnDemandEnabled
    }

    func commitManagerPreferences(
        _ manager: NETunnelProviderManager,
        newReference: Data,
        oldReference: Data?,
        shouldReloadForOnDemand: Bool
    ) async throws {
        do {
            try await manager.saveToPreferences()
        } catch {
            Log.error("Save: Saving configuration failed: \(error)")
            profileStore.delete(reference: newReference)
            throw TunnelError.saveFailed(TunnelError.describeSystemError(error))
        }

        if let oldReference, oldReference != newReference {
            profileStore.delete(reference: oldReference)
            idByPasswordReference.removeValue(forKey: oldReference)
        }

        if shouldReloadForOnDemand {
            // Quirk #3: After enabling or modifying on-demand, reload from preferences
            // or iOS stops delivering connection status updates.
            do {
                try await manager.loadFromPreferences()
            } catch {
                Log.error("Save: Reloading after enabling on-demand failed: \(error)")
                throw TunnelError.saveFailed(TunnelError.describeSystemError(error))
            }
        }
    }

    func resolveStableID(
        for manager: NETunnelProviderManager,
        passwordReference: Data?,
        name: String,
        claimedIDs: inout Set<UUID>
    ) -> UUID {
        if let passwordReference, let existing = idByPasswordReference[passwordReference], claimedIDs.insert(existing).inserted {
            return existing
        }
        if let existing = idByObjectID[ObjectIdentifier(manager)], claimedIDs.insert(existing).inserted {
            return existing
        }
        if let matchingEntry = managersByID.first(where: {
            $0.value.localizedDescription == name && !claimedIDs.contains($0.key)
        }) {
            claimedIDs.insert(matchingEntry.key)
            return matchingEntry.key
        }
        let freshID = UUID()
        claimedIDs.insert(freshID)
        return freshID
    }
}
