// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore

extension TunnelActivationService {
    func shouldActivateOnToggle(for tunnel: Tunnel) -> Bool {
        if tunnel.hasOnDemandRules {
            return !tunnel.isOnDemandEnabled
        }
        return tunnel.status == .inactive
    }

    func toggleTunnel(_ tunnel: Tunnel) async {
        if tunnel.hasOnDemandRules {
            await setTunnelActive(!tunnel.isOnDemandEnabled, for: tunnel)
        } else if tunnel.status == .inactive {
            await setTunnelActive(true, for: tunnel)
        } else if tunnel.status != .deactivating {
            await setTunnelActive(false, for: tunnel)
        }
    }

    func setTunnelActive(_ isOn: Bool, for tunnel: Tunnel) async {
        observer?.activationService(self, didClearActivationErrorForTunnelNamed: tunnel.name)

        if tunnel.hasOnDemandRules {
            do {
                try await applyOnDemandEnabled(isOn, for: tunnel)
                if !isOn {
                    await deactivateTunnel(tunnel)
                }
            } catch {
                observer?.activationService(
                    self,
                    didEncounterControlError: wrapError(error, fallback: TunnelError.saveFailed)
                )
            }
            return
        }

        if isOn {
            await startActivation(of: tunnel)
        } else {
            await deactivateTunnel(tunnel)
        }
    }

    func applyOnDemandEnabled(_ isOn: Bool, for tunnel: Tunnel) async throws {
        let record = try await backend.setOnDemandEnabled(isOn, for: tunnel.id)
        tunnel.onDemandPolicy = record.onDemandPolicy
        tunnel.isOnDemandEnabled = record.isOnDemandEnabled
        bumpRevision()
        syncStatusSnapshot()
        observer?.activationServiceDidUpdateTunnels(self)
    }

    func startActivation(of tunnel: Tunnel) async {
        guard tunnels.contains(where: { $0.id == tunnel.id }) else {
            failWaiters(for: tunnel.id, target: .active, error: WaitError.tunnelError(.tunnelNotFound))
            return
        }
        guard tunnel.status == .inactive else {
            let msg = L10n.tr("error.activation.notInactive", defaultValue: "The tunnel is not inactive.")
            let error = TunnelError.activationAttemptFailed(msg)
            observer?.activationService(self, didRecordActivationError: error, forTunnelNamed: tunnel.name)
            failWaiters(for: tunnel.id, target: .active, error: WaitError.tunnelError(error))
            return
        }

        if let existingWaitingID = waitingTunnelID,
           let existingWaiting = self.tunnel(for: existingWaitingID) {
            existingWaiting.status = .inactive
            waitingTunnelID = nil
            waiteeTunnelID = nil
            let msg = L10n.tr("error.activation.superseded", defaultValue: "Activation was superseded by another tunnel.")
            failWaiters(for: existingWaitingID, target: .active, error: WaitError.tunnelError(.activationAttemptFailed(msg)))
            succeedWaiters(for: existingWaitingID, target: .inactive, status: .inactive)
        }

        if let runningTunnel = tunnels.first(where: { $0.id != tunnel.id && $0.status != .inactive }) {
            await switchFromRunningTunnel(runningTunnel, to: tunnel)
            return
        }

        await activateDirect(tunnel)
    }

    func deactivateTunnel(_ tunnel: Tunnel) async {
        attemptingActivationIDs.remove(tunnel.id)
        restartingTunnelIDs.remove(tunnel.id)

        let cancelledMsg = L10n.tr("error.activation.cancelled", defaultValue: "Activation was cancelled.")
        if waitingTunnelID == tunnel.id {
            waitingTunnelID = nil
            waiteeTunnelID = nil
            tunnel.status = .inactive
            failWaiters(for: tunnel.id, target: .active, error: WaitError.tunnelError(.activationAttemptFailed(cancelledMsg)))
            succeedWaiters(for: tunnel.id, target: .inactive, status: .inactive)
            syncStatusSnapshot()
            updateTransitionPolling()
            return
        }

        if tunnel.status == .inactive {
            succeedWaiters(for: tunnel.id, target: .inactive, status: .inactive)
            return
        }

        failWaiters(for: tunnel.id, target: .active, error: WaitError.tunnelError(.activationAttemptFailed(cancelledMsg)))

        guard tunnel.status != .deactivating else { return }
        tunnel.status = .deactivating
        syncStatusSnapshot()
        updateTransitionPolling()
        await backend.stop(id: tunnel.id)
    }

    func handleStatusChange(tunnelID: Tunnel.ID, status newStatus: TunnelStatus) async {
        guard let tunnel = tunnel(for: tunnelID) else { return }

        if attemptingActivationIDs.contains(tunnelID) {
            await handleActivationAttemptStatusChange(tunnel: tunnel, newStatus: newStatus)
        } else if newStatus == .inactive && restartingTunnelIDs.contains(tunnelID) {
            restartingTunnelIDs.remove(tunnelID)
            tunnel.status = .inactive
            if let action = pendingDeactivationActions.removeValue(forKey: tunnelID) {
                await action()
            }
            await activateDirect(tunnel)
            syncStatusSnapshot()
            updateTransitionPolling()
            return
        } else if tunnel.status == .restarting && newStatus != .inactive {
            // Preserve synthetic restarting status until the tunnel reaches inactive.
        } else if tunnelID == waitingTunnelID && newStatus == .inactive {
            // Preserve synthetic waiting status while waiting on another tunnel to stop.
        } else {
            tunnel.status = newStatus
            if newStatus == .active {
                succeedWaiters(for: tunnelID, target: .active, status: .active)
            } else if newStatus == .inactive && hasWaiter(for: tunnelID, target: .active) {
                let error = await resolveActivationFailureError(for: tunnelID)
                failWaiters(for: tunnelID, target: .active, error: WaitError.tunnelError(error))
            }
        }

        if newStatus == .inactive {
            await handleTunnelBecameInactive(tunnelID: tunnelID)
        }
        syncStatusSnapshot()
        updateTransitionPolling()
    }

    func restartEditedTunnel(_ tunnel: Tunnel) async {
        restartingTunnelIDs.insert(tunnel.id)
        attemptingActivationIDs.remove(tunnel.id)
        tunnel.status = .restarting
        syncStatusSnapshot()
        updateTransitionPolling()
        await backend.stop(id: tunnel.id)
    }

    func recoverActiveTunnelAfterAdd(_ activeTunnel: Tunnel) async {
        if activeTunnel.status == .inactive {
            await startActivation(of: activeTunnel)
        } else if activeTunnel.status == .deactivating
            || activeTunnel.status == .active
            || activeTunnel.status == .activating {
            restartingTunnelIDs.insert(activeTunnel.id)
            attemptingActivationIDs.remove(activeTunnel.id)
            activeTunnel.status = .restarting
            syncStatusSnapshot()
            updateTransitionPolling()
        }
    }

    func stopAndWaitForDeactivation(of tunnel: Tunnel) async {
        attemptingActivationIDs.remove(tunnel.id)
        restartingTunnelIDs.remove(tunnel.id)
        if tunnel.status == .inactive {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingDeactivationActions[tunnel.id] = {
                continuation.resume()
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if tunnel.status != .deactivating && tunnel.status != .inactive {
                    tunnel.status = .deactivating
                }
                self.syncStatusSnapshot()
                self.updateTransitionPolling()
                await self.backend.stop(id: tunnel.id)
                if tunnel.status == .inactive,
                   let action = self.pendingDeactivationActions.removeValue(forKey: tunnel.id) {
                    await action()
                }
            }
        }
    }

    func updateTransitionPolling() {
        if hasTransitioningTunnel {
            let interval = effectiveTransitionPollInterval
            if transitionPollTask != nil && activePollInterval == interval {
                return
            }
            transitionPollTask?.cancel()
            activePollInterval = interval
            transitionPollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        return
                    }
                    guard let self, !Task.isCancelled else { return }
                    await self.refreshStatuses()
                    if !self.hasTransitioningTunnel {
                        self.transitionPollTask = nil
                        self.activePollInterval = nil
                        return
                    }
                }
            }
        } else {
            transitionPollTask?.cancel()
            transitionPollTask = nil
            activePollInterval = nil
        }
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
                failWaiters(
                    for: nextID,
                    target: .active,
                    error: WaitError.tunnelError(.activationAttemptFailed(
                        L10n.tr("error.activation.previousRemoved", defaultValue: "The previous tunnel was removed.")
                    ))
                )
            }
        }
        failWaiters(for: id, target: .active, error: WaitError.tunnelError(.tunnelNotFound))
        failWaiters(for: id, target: .inactive, error: WaitError.tunnelError(.tunnelNotFound))
        if let action = pendingDeactivationActions.removeValue(forKey: id) {
            Task { @MainActor in
                await action()
            }
        }
    }

    private var hasTransitioningTunnel: Bool {
        tunnels.contains { $0.status.isTransitioning }
            || !attemptingActivationIDs.isEmpty
            || !restartingTunnelIDs.isEmpty
            || !pendingDeactivationActions.isEmpty
            || statusWaiters.values.contains { !$0.isEmpty }
    }

    private var effectiveTransitionPollInterval: Duration {
        let hasActiveWaiters = statusWaiters.values.contains { !$0.isEmpty }
        if hasActiveWaiters {
            return min(transitionPollInterval, .seconds(1))
        }
        return transitionPollInterval
    }
}

private extension TunnelActivationService {
    func switchFromRunningTunnel(_ runningTunnel: Tunnel, to nextTunnel: Tunnel) async {
        Log.info("Tunnel '\(nextTunnel.name)' waiting for deactivation of '\(runningTunnel.name)'")
        nextTunnel.status = .waiting
        waitingTunnelID = nextTunnel.id
        waiteeTunnelID = runningTunnel.id
        restartingTunnelIDs.remove(runningTunnel.id)
        syncStatusSnapshot()
        updateTransitionPolling()

        guard runningTunnel.status != .deactivating else { return }

        if runningTunnel.isOnDemandEnabled {
            do {
                let record = try await backend.setOnDemandEnabled(false, for: runningTunnel.id)
                runningTunnel.isOnDemandEnabled = record.isOnDemandEnabled
            } catch {
                Log.error("Failed to disable on-demand on '\(runningTunnel.name)' while switching: \(error)")
                nextTunnel.status = .inactive
                waitingTunnelID = nil
                waiteeTunnelID = nil
                let wrapped = wrapError(error, fallback: TunnelError.saveFailed)
                observer?.activationService(self, didEncounterControlError: wrapped)
                failWaiters(for: nextTunnel.id, target: .active, error: WaitError.tunnelError(wrapped))
                syncStatusSnapshot()
                updateTransitionPolling()
                return
            }
        }
        await deactivateTunnel(runningTunnel)
    }

    func activateDirect(_ tunnel: Tunnel) async {
        tunnel.status = .activating
        attemptingActivationIDs.insert(tunnel.id)
        syncStatusSnapshot()
        updateTransitionPolling()

        do {
            try await backend.start(id: tunnel.id)
            RecentTunnelsTracker.handleTunnelActivated(
                tunnelID: tunnel.id,
                userDefaults: recentTunnelsUserDefaults
            )
            observer?.activationServiceDidUpdateTunnels(self)
        } catch {
            attemptingActivationIDs.remove(tunnel.id)
            tunnel.status = .inactive
            syncStatusSnapshot()
            updateTransitionPolling()
            let tunnelError: TunnelError
            if let existing = error as? TunnelError {
                tunnelError = existing
            } else if let startError = await backend.fetchLastStartError(for: tunnel.id) {
                tunnelError = .startFailed(startError)
            } else {
                tunnelError = .activationAttemptFailed(TunnelError.describeSystemError(error))
            }
            observer?.activationService(self, didRecordActivationError: tunnelError, forTunnelNamed: tunnel.name)
            failWaiters(for: tunnel.id, target: .active, error: WaitError.tunnelError(tunnelError))
        }
    }

    func handleActivationAttemptStatusChange(tunnel: Tunnel, newStatus: TunnelStatus) async {
        switch newStatus {
        case .active:
            attemptingActivationIDs.remove(tunnel.id)
            tunnel.status = .active
            observer?.activationService(self, didClearActivationErrorForTunnelNamed: tunnel.name)
            succeedWaiters(for: tunnel.id, target: .active, status: .active)
        case .inactive:
            attemptingActivationIDs.remove(tunnel.id)
            tunnel.status = .inactive
            let error = await resolveActivationFailureError(for: tunnel.id)
            observer?.activationService(self, didRecordActivationError: error, forTunnelNamed: tunnel.name)
            failWaiters(for: tunnel.id, target: .active, error: WaitError.tunnelError(error))
        default:
            tunnel.status = newStatus
        }
    }

    func resolveActivationFailureError(for tunnelID: Tunnel.ID) async -> TunnelError {
        if let startError = await backend.fetchLastStartError(for: tunnelID) {
            return .startFailed(startError)
        }
        return .activationAttemptFailed(
            L10n.tr("error.activation.generic", defaultValue: "The tunnel could not be activated.")
        )
    }

    func handleTunnelBecameInactive(tunnelID: Tunnel.ID) async {
        succeedWaiters(for: tunnelID, target: .inactive, status: .inactive)
        if let action = pendingDeactivationActions.removeValue(forKey: tunnelID) {
            await action()
        }
        if waiteeTunnelID == tunnelID {
            waiteeTunnelID = nil
            if let nextID = waitingTunnelID, let nextTunnel = tunnel(for: nextID) {
                waitingTunnelID = nil
                nextTunnel.status = .inactive
                await activateDirect(nextTunnel)
            }
        }
    }
}
