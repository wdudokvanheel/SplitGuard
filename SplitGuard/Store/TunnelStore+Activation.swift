// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore

extension TunnelStore {
    func setTunnelActive(_ isOn: Bool, for tunnel: Tunnel) async {
        clearActivationError(for: tunnel.name)

        if tunnel.hasOnDemandRules {
            do {
                let record = try await backend.setOnDemandEnabled(isOn, for: tunnel.id)
                tunnel.onDemandPolicy = record.onDemandPolicy
                tunnel.isOnDemandEnabled = record.isOnDemandEnabled
                bumpRevision()
                if !isOn {
                    await deactivateTunnel(tunnel)
                }
            } catch {
                present(error: wrapError(error, fallback: TunnelError.saveFailed))
            }
            return
        }

        if isOn {
            await startActivation(of: tunnel)
        } else {
            await deactivateTunnel(tunnel)
        }
    }

    func startActivation(of tunnel: Tunnel) async {
        guard tunnels.contains(where: { $0.id == tunnel.id }) else { return }
        guard tunnel.status == .inactive else {
            recordActivationError(
                tunnelName: tunnel.name,
                error: .activationAttemptFailed("The tunnel is not inactive.")
            )
            return
        }

        if let existingWaitingID = waitingTunnelID,
           let existingWaiting = self.tunnel(for: existingWaitingID) {
            existingWaiting.status = .inactive
            waitingTunnelID = nil
            waiteeTunnelID = nil
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

        if waitingTunnelID == tunnel.id {
            waitingTunnelID = nil
            waiteeTunnelID = nil
            tunnel.status = .inactive
            updateTransitionPolling()
            return
        }

        guard tunnel.status != .inactive && tunnel.status != .deactivating else { return }
        tunnel.status = .deactivating
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
            updateTransitionPolling()
            return
        } else if tunnel.status == .restarting && newStatus != .inactive {
            // Preserve synthetic restarting status until the tunnel reaches inactive.
        } else if tunnelID == waitingTunnelID && newStatus == .inactive {
            // Preserve synthetic waiting status while waiting on another tunnel to stop.
        } else {
            tunnel.status = newStatus
        }

        if newStatus == .inactive {
            await handleTunnelBecameInactive(tunnelID: tunnelID)
        }
        updateTransitionPolling()
    }

    func restartEditedTunnel(_ tunnel: Tunnel) async {
        restartingTunnelIDs.insert(tunnel.id)
        attemptingActivationIDs.remove(tunnel.id)
        tunnel.status = .restarting
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
            guard transitionPollTask == nil else { return }
            let interval = transitionPollInterval
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
                        return
                    }
                }
            }
        } else {
            transitionPollTask?.cancel()
            transitionPollTask = nil
        }
    }

    private var hasTransitioningTunnel: Bool {
        tunnels.contains { $0.status.isTransitioning }
            || !attemptingActivationIDs.isEmpty
            || !restartingTunnelIDs.isEmpty
            || !pendingDeactivationActions.isEmpty
    }
}

private extension TunnelStore {
    func switchFromRunningTunnel(_ runningTunnel: Tunnel, to nextTunnel: Tunnel) async {
        Log.info("Tunnel '\(nextTunnel.name)' waiting for deactivation of '\(runningTunnel.name)'")
        nextTunnel.status = .waiting
        waitingTunnelID = nextTunnel.id
        waiteeTunnelID = runningTunnel.id
        restartingTunnelIDs.remove(runningTunnel.id)
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
                present(error: wrapError(error, fallback: TunnelError.saveFailed))
                updateTransitionPolling()
                return
            }
        }
        await deactivateTunnel(runningTunnel)
    }

    func activateDirect(_ tunnel: Tunnel) async {
        tunnel.status = .activating
        attemptingActivationIDs.insert(tunnel.id)
        updateTransitionPolling()

        do {
            try await backend.start(id: tunnel.id)
            RecentTunnelsTracker.handleTunnelActivated(
                tunnelID: tunnel.id,
                userDefaults: recentTunnelsUserDefaults
            )
            updateQuickActions()
        } catch {
            attemptingActivationIDs.remove(tunnel.id)
            tunnel.status = .inactive
            updateTransitionPolling()
            let tunnelError: TunnelError
            if let existing = error as? TunnelError {
                tunnelError = existing
            } else if let startError = await backend.fetchLastStartError(for: tunnel.id) {
                tunnelError = .startFailed(startError)
            } else {
                tunnelError = .activationAttemptFailed(TunnelError.describeSystemError(error))
            }
            recordActivationError(tunnelName: tunnel.name, error: tunnelError)
        }
    }

    func handleActivationAttemptStatusChange(tunnel: Tunnel, newStatus: TunnelStatus) async {
        switch newStatus {
        case .active:
            attemptingActivationIDs.remove(tunnel.id)
            tunnel.status = .active
            clearActivationError(for: tunnel.name)
        case .inactive:
            attemptingActivationIDs.remove(tunnel.id)
            tunnel.status = .inactive
            if let startError = await backend.fetchLastStartError(for: tunnel.id) {
                recordActivationError(tunnelName: tunnel.name, error: .startFailed(startError))
            } else {
                recordActivationError(
                    tunnelName: tunnel.name,
                    error: .activationAttemptFailed("The tunnel could not be activated.")
                )
            }
        default:
            tunnel.status = newStatus
        }
    }

    func handleTunnelBecameInactive(tunnelID: Tunnel.ID) async {
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
