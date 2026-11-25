// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore

extension TunnelActivationService {
    struct ConnectOutcome {
        let tunnel: Tunnel
        let enabledOnDemand: Bool
        let alreadyActive: Bool
    }

    enum ToggleAction: Equatable {
        case connected
        case disconnected
        case enabledOnDemand
        case disabledOnDemand
    }

    struct ToggleOutcome {
        let tunnel: Tunnel
        let action: ToggleAction
    }

    // MARK: - Intent-Facing Operations

    func entitySnapshots() async -> [TunnelStatusSnapshot.Entry] {
        do {
            try await ensureLoaded()
            await refreshStatuses()
            let now = Date()
            return tunnels.map { tunnel in
                TunnelStatusSnapshot.Entry(
                    id: tunnel.id,
                    name: tunnel.name,
                    status: tunnel.status.snapshotStatus,
                    hasOnDemandRules: tunnel.hasOnDemandRules,
                    isOnDemandEnabled: tunnel.isOnDemandEnabled,
                    updatedAt: now
                )
            }
        } catch {
            Log.warning("Falling back to cached status snapshot after load failure: \(error.localizedDescription)")
            return snapshotStore?.load().entries ?? []
        }
    }

    func statusForIntent(tunnelID: Tunnel.ID?) async throws -> Tunnel? {
        try await ensureLoaded()
        await refreshStatuses()
        if let tunnelID {
            guard let tunnel = tunnel(for: tunnelID) else {
                throw TunnelError.tunnelNotFound
            }
            return tunnel
        }
        return activeTunnel
    }

    func connectAndWait(tunnelID: Tunnel.ID, timeout: Duration? = nil) async throws -> ConnectOutcome {
        let effectiveTimeout = timeout ?? defaultOperationTimeout
        try await ensureLoaded()
        await refreshStatuses()

        guard let tunnel = tunnel(for: tunnelID) else {
            throw TunnelError.tunnelNotFound
        }

        observer?.activationService(self, didClearActivationErrorForTunnelNamed: tunnel.name)

        if tunnel.hasOnDemandRules {
            let wasAlreadyActive = tunnel.isOnDemandEnabled && tunnel.status == .active
            if !tunnel.isOnDemandEnabled {
                do {
                    try await applyOnDemandEnabled(true, for: tunnel)
                } catch {
                    throw wrapError(error, fallback: TunnelError.saveFailed)
                }
            }
            return ConnectOutcome(tunnel: tunnel, enabledOnDemand: true, alreadyActive: wasAlreadyActive)
        }

        if tunnel.status == .active {
            return ConnectOutcome(tunnel: tunnel, enabledOnDemand: false, alreadyActive: true)
        }

        if tunnel.status == .deactivating {
            let deactivateWaiter = registerWaiter(for: tunnel.id, target: .inactive, timeout: effectiveTimeout)
            _ = try await awaitWaiter(deactivateWaiter, for: tunnel.id)
        }

        if tunnel.status == .active {
            return ConnectOutcome(tunnel: tunnel, enabledOnDemand: false, alreadyActive: false)
        }

        let waiter = registerWaiter(for: tunnel.id, target: .active, timeout: effectiveTimeout)
        if tunnel.status == .inactive {
            await startActivation(of: tunnel)
        }
        _ = try await awaitWaiter(waiter, for: tunnel.id)
        return ConnectOutcome(tunnel: tunnel, enabledOnDemand: false, alreadyActive: false)
    }

    func disconnectAndWait(tunnelID: Tunnel.ID, timeout: Duration? = nil) async throws -> Tunnel {
        let effectiveTimeout = timeout ?? defaultOperationTimeout
        try await ensureLoaded()
        await refreshStatuses()

        guard let tunnel = tunnel(for: tunnelID) else {
            throw TunnelError.tunnelNotFound
        }

        if tunnel.hasOnDemandRules && tunnel.isOnDemandEnabled {
            do {
                try await applyOnDemandEnabled(false, for: tunnel)
            } catch {
                throw wrapError(error, fallback: TunnelError.saveFailed)
            }
        }

        if tunnel.status == .inactive {
            return tunnel
        }

        let waiter = registerWaiter(for: tunnel.id, target: .inactive, timeout: effectiveTimeout)
        await deactivateTunnel(tunnel)
        if tunnel.status == .inactive {
            succeedWaiters(for: tunnel.id, target: .inactive, status: .inactive)
        }
        _ = try await awaitWaiter(waiter, for: tunnel.id)
        return tunnel
    }

    func toggleAndWait(tunnelID: Tunnel.ID, timeout: Duration? = nil) async throws -> ToggleOutcome {
        let effectiveTimeout = timeout ?? defaultOperationTimeout
        try await ensureLoaded()
        await refreshStatuses()

        guard let tunnel = tunnel(for: tunnelID) else {
            throw TunnelError.tunnelNotFound
        }

        if tunnel.hasOnDemandRules {
            if tunnel.isOnDemandEnabled {
                let updated = try await disconnectAndWait(tunnelID: tunnelID, timeout: effectiveTimeout)
                return ToggleOutcome(tunnel: updated, action: .disabledOnDemand)
            }
            let outcome = try await connectAndWait(tunnelID: tunnelID, timeout: effectiveTimeout)
            return ToggleOutcome(tunnel: outcome.tunnel, action: .enabledOnDemand)
        }

        if tunnel.status == .inactive || tunnel.status == .deactivating {
            let outcome = try await connectAndWait(tunnelID: tunnelID, timeout: effectiveTimeout)
            return ToggleOutcome(tunnel: outcome.tunnel, action: .connected)
        }

        let updated = try await disconnectAndWait(tunnelID: tunnelID, timeout: effectiveTimeout)
        return ToggleOutcome(tunnel: updated, action: .disconnected)
    }

    func disconnectActiveAndWait(timeout: Duration? = nil) async throws -> Tunnel? {
        let effectiveTimeout = timeout ?? defaultOperationTimeout
        try await ensureLoaded()
        await refreshStatuses()

        guard let active = activeTunnel else {
            return nil
        }
        return try await disconnectAndWait(tunnelID: active.id, timeout: effectiveTimeout)
    }

    // MARK: - Waiter Lifecycle

    func hasWaiter(for tunnelID: Tunnel.ID, target: WaitTarget) -> Bool {
        statusWaiters[tunnelID]?.contains { $0.target == target } ?? false
    }

    func registerWaiter(for tunnelID: Tunnel.ID, target: WaitTarget, timeout: Duration) -> Waiter {
        let waiter = Waiter(target: target)
        statusWaiters[tunnelID, default: []].append(waiter)
        waiter.timeoutTask = Task { @MainActor [weak self, weak waiter] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self, let waiter else { return }
            self.resolveWaiter(waiter, for: tunnelID, result: .failure(WaitError.timedOut))
        }
        updateTransitionPolling()
        return waiter
    }

    func awaitWaiter(_ waiter: Waiter, for tunnelID: Tunnel.ID) async throws -> TunnelStatus {
        if let completed = waiter.result {
            return try completed.get()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let completed = waiter.result {
                    continuation.resume(with: completed)
                } else {
                    waiter.continuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self, weak waiter] in
                guard let self, let waiter else { return }
                self.resolveWaiter(waiter, for: tunnelID, result: .failure(CancellationError()))
            }
        }
    }

    func succeedWaiters(for tunnelID: Tunnel.ID, target: WaitTarget, status: TunnelStatus) {
        guard let list = statusWaiters[tunnelID], !list.isEmpty else { return }
        let matching = list.filter { $0.target == target }
        for waiter in matching {
            resolveWaiter(waiter, for: tunnelID, result: .success(status))
        }
    }

    func failWaiters(for tunnelID: Tunnel.ID, target: WaitTarget, error: Error) {
        guard let list = statusWaiters[tunnelID], !list.isEmpty else { return }
        let matching = list.filter { $0.target == target }
        for waiter in matching {
            resolveWaiter(waiter, for: tunnelID, result: .failure(error))
        }
    }

    private func resolveWaiter(_ waiter: Waiter, for tunnelID: Tunnel.ID, result: Result<TunnelStatus, Error>) {
        guard waiter.result == nil else { return }
        waiter.result = result
        waiter.timeoutTask?.cancel()
        waiter.timeoutTask = nil

        if var list = statusWaiters[tunnelID] {
            list.removeAll { $0.id == waiter.id }
            if list.isEmpty {
                statusWaiters.removeValue(forKey: tunnelID)
            } else {
                statusWaiters[tunnelID] = list
            }
        }

        let continuation = waiter.continuation
        waiter.continuation = nil
        updateTransitionPolling()
        continuation?.resume(with: result)
    }
}
