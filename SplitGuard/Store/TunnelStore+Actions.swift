// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore

extension TunnelStore {
    // MARK: - CRUD

    @discardableResult
    func addTunnel(
        _ profile: TunnelProfile,
        onDemandPolicy: OnDemandPolicy = .off
    ) async throws -> Tunnel {
        let trimmedName = try validateNewTunnelName(profile.name, excludingID: nil)
        var normalizedProfile = profile
        normalizedProfile.name = trimmedName
        let normalizedPolicy = onDemandPolicy.normalized()

        // Quirk #1: Saving a new VPN configuration can deactivate a running tunnel on iOS.
        let previouslyActiveTunnel = tunnels.first { $0.status == .active || $0.status == .activating }

        let record: TunnelRecord
        do {
            record = try await backend.save(
                normalizedProfile,
                onDemandPolicy: normalizedPolicy,
                isOnDemandEnabled: false,
                replacing: nil
            )
        } catch {
            throw wrapError(error, fallback: TunnelError.saveFailed)
        }

        let created = Tunnel(record: record)
        appendTunnel(created)
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
        onDemandPolicy: OnDemandPolicy
    ) async throws -> Tunnel {
        let trimmedName = try validateNewTunnelName(profile.name, excludingID: tunnel.id)
        let oldName = tunnel.name
        var normalizedProfile = profile
        normalizedProfile.name = trimmedName
        let normalizedPolicy = onDemandPolicy.normalized()

        // Quirk #2: Introducing on-demand rules on a running tunnel requires stopping it first.
        let shouldEnsureOnDemandEnabled = try await prepareForOnDemandIntroductionIfNeeded(
            tunnel: tunnel,
            newPolicy: normalizedPolicy
        )

        let isConfigurationChanged = tunnel.profile != normalizedProfile
        let targetOnDemandEnabled = normalizedPolicy.hasRules && (
            shouldEnsureOnDemandEnabled || tunnel.isOnDemandEnabled
        )

        let record: TunnelRecord
        do {
            record = try await backend.save(
                normalizedProfile,
                onDemandPolicy: normalizedPolicy,
                isOnDemandEnabled: targetOnDemandEnabled,
                replacing: tunnel.id
            )
        } catch {
            throw wrapError(error, fallback: TunnelError.saveFailed)
        }

        applyUpdateResult(tunnel: tunnel, record: record, oldName: oldName, newName: trimmedName)

        if isConfigurationChanged,
           tunnel.status == .active || tunnel.status == .activating || tunnel.status == .reasserting {
            await restartEditedTunnel(tunnel)
        }

        return tunnel
    }

    @discardableResult
    func saveTunnel(
        existing tunnel: Tunnel?,
        profile: TunnelProfile,
        onDemandPolicy: OnDemandPolicy = .off
    ) async throws -> Tunnel {
        if let tunnel {
            return try await updateTunnel(tunnel, profile: profile, onDemandPolicy: onDemandPolicy)
        }
        return try await addTunnel(profile, onDemandPolicy: onDemandPolicy)
    }

    @discardableResult
    func delete(tunnel: Tunnel) async -> Bool {
        do {
            try await backend.remove(id: tunnel.id)
        } catch {
            present(error: wrapError(error, fallback: TunnelError.removeFailed))
            return false
        }

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
        QuickActionCoordinator.shared.updateShortcutItems(allTunnelNames: tunnels.map(\.name))
    }

    func handleQuickAction(tunnelName: String) {
        guard hasLoaded else {
            pendingQuickActionTunnelName = tunnelName
            return
        }
        guard let tunnel = tunnel(named: tunnelName) else { return }
        requestedNavigationTunnelID = tunnel.id

        let state = displayState(for: tunnel)
        if state.hasOnDemandRules {
            Task { [weak self] in
                await self?.setTunnelActive(!state.isOnDemandEnabled, for: tunnel)
            }
        } else if state.status == .inactive {
            Task { [weak self] in
                await self?.setTunnelActive(true, for: tunnel)
            }
        } else if state.status == .active {
            Task { [weak self] in
                await self?.setTunnelActive(false, for: tunnel)
            }
        }
    }

    func flushPendingQuickAction() {
        guard let pendingName = pendingQuickActionTunnelName else { return }
        pendingQuickActionTunnelName = nil
        handleQuickAction(tunnelName: pendingName)
    }

    func consumeRequestedNavigationTunnelID() -> Tunnel.ID? {
        defer { requestedNavigationTunnelID = nil }
        return requestedNavigationTunnelID
    }

    // MARK: - Split DNS Suggestions

    func evaluateSplitDNSSuggestion(for newlyAddedTunnels: [Tunnel]) {
        guard pendingSplitDNSSuggestion == nil else { return }
        for tunnel in newlyAddedTunnels {
            guard tunnel.splitDNS.mode == .allDomains else { continue }
            let endpoints = tunnel.profile.peers.compactMap(\.endpoint)
            guard let suggestedDomain = SplitDNSConfiguration.endpointDomainSuggestion(from: endpoints) else {
                continue
            }
            pendingSplitDNSSuggestion = SplitDNSSuggestionPrompt(
                tunnelID: tunnel.id,
                tunnelName: tunnel.name,
                suggestedDomain: suggestedDomain,
                dnsServers: tunnel.profile.interface.dnsServers.map(\.description)
            )
            return
        }
    }

    @discardableResult
    func applySplitDNSSuggestion(
        for tunnelID: Tunnel.ID,
        domains: [SplitDNSConfiguration.Domain],
        exclusions: [SplitDNSConfiguration.Exclusion] = []
    ) async -> Bool {
        guard let tunnel = tunnel(for: tunnelID) else {
            pendingSplitDNSSuggestion = nil
            return false
        }

        var resolvedExclusions = exclusions
        let endpointHostnames = Set(
            tunnel.profile.peers.compactMap { $0.endpoint?.hostname }
                .map(SplitDNSConfiguration.normalizeDomain)
        )
        for domain in domains where endpointHostnames.contains(domain.name) {
            if !resolvedExclusions.contains(where: { $0.name == domain.name }) {
                resolvedExclusions.append(.init(name: domain.name, includesSubdomains: false))
            }
        }

        var updatedProfile = tunnel.profile
        updatedProfile.splitDNS = SplitDNSConfiguration(
            mode: .onlyDomains,
            domains: domains,
            exclusions: resolvedExclusions
        )

        do {
            _ = try await updateTunnel(
                tunnel,
                profile: updatedProfile,
                onDemandPolicy: tunnel.onDemandPolicy
            )
            pendingSplitDNSSuggestion = nil
            return true
        } catch {
            present(error: wrapError(error, fallback: TunnelError.saveFailed))
            return false
        }
    }

    func dismissSplitDNSSuggestion() {
        pendingSplitDNSSuggestion = nil
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

    func applyUpdateResult(tunnel: Tunnel, record: TunnelRecord, oldName: String, newName: String) {
        tunnel.apply(record: record)
        if oldName != newName {
            sortTunnels()
            RecentTunnelsTracker.handleTunnelRenamed(
                oldName: oldName,
                newName: newName,
                userDefaults: recentTunnelsUserDefaults
            )
            if favoriteTunnelName == oldName {
                setFavorite(tunnel)
            }
        }
        bumpRevision()
        updateQuickActions()
    }

    func removeDeletedTunnelLocally(_ tunnel: Tunnel) {
        let removedName = tunnel.name
        cleanupState(forRemovedID: tunnel.id)
        removeTunnelFromList(id: tunnel.id)
        if favoriteTunnelName == removedName {
            setFavorite(nil)
        }
        clearActivationError(for: removedName)
        RecentTunnelsTracker.handleTunnelRemoved(
            tunnelName: removedName,
            userDefaults: recentTunnelsUserDefaults
        )
    }
}
