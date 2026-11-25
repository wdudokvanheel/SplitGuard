// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore

extension TunnelStore {
    // MARK: - CRUD

    @discardableResult
    func addTunnel(
        _ profile: TunnelProfile,
        onDemandPolicy: OnDemandPolicy = .off,
        localSettings: TunnelLocalSettings = .default
    ) async throws -> Tunnel {
        let trimmedName = try validateNewTunnelName(profile.name, excludingID: nil)
        var normalizedProfile = profile
        normalizedProfile.name = trimmedName
        let normalizedPolicy = onDemandPolicy.normalized()

        // Quirk #1: Saving a new VPN configuration can deactivate a running tunnel on iOS.
        let previouslyActiveTunnel = tunnels.first { $0.status == .active || $0.status == .activating }

        markLocalMutation()
        let record: TunnelRecord
        do {
            record = try await backend.save(
                normalizedProfile,
                onDemandPolicy: normalizedPolicy,
                isOnDemandEnabled: false,
                localSettings: localSettings,
                replacing: nil
            )
        } catch {
            throw wrapError(error, fallback: TunnelError.saveFailed)
        }
        markLocalMutation()

        let created = upsertTunnel(from: record)
        sortTunnels()
        bumpRevision()
        updateQuickActions()

        if backend.saveNewDeactivatesActiveTunnel, let activeTunnel = previouslyActiveTunnel {
            await recoverActiveTunnelAfterAdd(activeTunnel)
        }

        return created
    }

    @discardableResult
    func updateTunnel(
        _ tunnel: Tunnel,
        profile: TunnelProfile,
        onDemandPolicy: OnDemandPolicy,
        localSettings: TunnelLocalSettings? = nil
    ) async throws -> Tunnel {
        let trimmedName = try validateNewTunnelName(profile.name, excludingID: tunnel.id)
        let isRenamed = tunnel.name != trimmedName
        var normalizedProfile = profile
        normalizedProfile.name = trimmedName
        let normalizedPolicy = onDemandPolicy.normalized()
        let effectiveLocalSettings = localSettings ?? tunnel.localSettings

        // Quirk #2: Introducing on-demand rules on a running tunnel requires stopping it first.
        let shouldEnsureOnDemandEnabled = try await prepareForOnDemandIntroductionIfNeeded(
            tunnel: tunnel,
            newPolicy: normalizedPolicy
        )

        let isConfigurationChanged = tunnel.profile != normalizedProfile
        let isLocalSettingsChanged = tunnel.localSettings != effectiveLocalSettings
        let targetOnDemandEnabled = normalizedPolicy.hasRules && (
            shouldEnsureOnDemandEnabled || tunnel.isOnDemandEnabled
        )

        markLocalMutation()
        let record: TunnelRecord
        do {
            record = try await backend.save(
                normalizedProfile,
                onDemandPolicy: normalizedPolicy,
                isOnDemandEnabled: targetOnDemandEnabled,
                localSettings: effectiveLocalSettings,
                replacing: tunnel.id
            )
        } catch {
            throw wrapError(error, fallback: TunnelError.saveFailed)
        }
        markLocalMutation()

        applyUpdateResult(tunnel: tunnel, record: record, isRenamed: isRenamed)

        let isRunning = tunnel.status == .active || tunnel.status == .activating || tunnel.status == .reasserting
        if isConfigurationChanged, isRunning {
            await restartEditedTunnel(tunnel)
        } else if isLocalSettingsChanged, isRunning {
            _ = await backend.sendProviderMessage(.updateLocalSettings(effectiveLocalSettings), to: tunnel.id)
        }

        return tunnel
    }

    @discardableResult
    func saveTunnel(
        existing tunnel: Tunnel?,
        profile: TunnelProfile,
        onDemandPolicy: OnDemandPolicy = .off,
        localSettings: TunnelLocalSettings = .default
    ) async throws -> Tunnel {
        if let tunnel {
            return try await updateTunnel(
                tunnel,
                profile: profile,
                onDemandPolicy: onDemandPolicy,
                localSettings: localSettings
            )
        }
        return try await addTunnel(
            profile,
            onDemandPolicy: onDemandPolicy,
            localSettings: localSettings
        )
    }

    @discardableResult
    func delete(tunnel: Tunnel) async -> Bool {
        markLocalMutation()
        do {
            try await backend.remove(id: tunnel.id)
        } catch {
            present(error: wrapError(error, fallback: TunnelError.removeFailed))
            return false
        }
        markLocalMutation()

        removeDeletedTunnelLocally(tunnel)
        bumpRevision()
        updateQuickActions()
        updateTransitionPolling()
        return true
    }

    @discardableResult
    func deleteMultiple(tunnels tunnelsToDelete: [Tunnel]) async -> Bool {
        guard !tunnelsToDelete.isEmpty else { return false }

        // Quirk #6: Suppress intermediate configuration-change notifications during bulk removal.
        markLocalMutation()
        await backend.setConfigurationChangeObservationPaused(true)
        var firstError: Error?

        for tunnel in tunnelsToDelete {
            do {
                try await backend.remove(id: tunnel.id)
                removeDeletedTunnelLocally(tunnel)
            } catch {
                firstError = error
                break
            }
        }
        markLocalMutation()

        await backend.setConfigurationChangeObservationPaused(false)
        await reloadFromBackend()

        if let firstError {
            present(error: wrapError(firstError, fallback: TunnelError.removeFailed))
            return false
        }
        return true
    }

    // MARK: - Quick Actions & Navigation

    func updateQuickActions() {
        QuickActionCoordinator.shared.updateShortcutItems(
            tunnels: tunnels.map { QuickActionItem.Target(id: $0.id, name: $0.name) }
        )
    }

    func handleQuickAction(tunnelID: Tunnel.ID) {
        guard hasLoaded else {
            pendingQuickActionTunnelID = tunnelID
            return
        }
        guard let tunnel = tunnel(for: tunnelID) else { return }
        requestedNavigationTunnelID = tunnel.id

        Task { [weak self] in
            await self?.toggleTunnel(tunnel)
        }
    }

    func flushPendingQuickAction() {
        guard let pendingID = pendingQuickActionTunnelID else { return }
        pendingQuickActionTunnelID = nil
        handleQuickAction(tunnelID: pendingID)
    }

    func consumeRequestedNavigationTunnelID() -> Tunnel.ID? {
        defer { requestedNavigationTunnelID = nil }
        return requestedNavigationTunnelID
    }

    @discardableResult
    func upsertTunnel(from record: TunnelRecord) -> Tunnel {
        activationService.upsertTunnel(from: record)
    }

    func markLocalMutation() {
        activationService.markLocalMutation()
    }
}

private extension TunnelStore {
    func validateNewTunnelName(_ rawName: String, excludingID: Tunnel.ID?) throws -> String {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw TunnelError.tunnelNameEmpty
        }
        if tunnels.contains(where: { $0.id != excludingID && $0.name == trimmedName }) {
            throw TunnelError.tunnelNameAlreadyExists(trimmedName)
        }
        return trimmedName
    }

    func prepareForOnDemandIntroductionIfNeeded(
        tunnel: Tunnel,
        newPolicy: OnDemandPolicy
    ) async throws -> Bool {
        let isIntroducingOnDemandRules = !tunnel.hasOnDemandRules && newPolicy.hasRules
        guard isIntroducingOnDemandRules && tunnel.status != .inactive && tunnel.status != .deactivating else {
            return false
        }
        await stopAndWaitForDeactivation(of: tunnel)
        guard tunnels.contains(where: { $0.id == tunnel.id }) else {
            throw TunnelError.tunnelNotFound
        }
        return true
    }

    func applyUpdateResult(tunnel: Tunnel, record: TunnelRecord, isRenamed: Bool) {
        tunnel.apply(record: record)
        if isRenamed {
            sortTunnels()
        } else {
            activationService.syncStatusSnapshot()
        }
        bumpRevision()
        updateQuickActions()
    }

    func removeDeletedTunnelLocally(_ tunnel: Tunnel) {
        activationService.removeTunnelLocally(id: tunnel.id)
        if favoriteTunnelID == tunnel.id {
            setFavorite(nil)
        }
        clearActivationError(for: tunnel.name)
    }
}
