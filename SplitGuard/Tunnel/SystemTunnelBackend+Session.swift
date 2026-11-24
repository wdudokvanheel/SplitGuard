// SPDX-License-Identifier: MIT

import Foundation
import NetworkExtension
import SplitGuardCore
import WireGuardEngine

extension SystemTunnelBackend {
    func start(id: UUID) async throws {
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

    func removeOrphanedManager(_ manager: NETunnelProviderManager) async {
        Log.info("Removing orphaned tunnel '\(manager.localizedDescription ?? "<unknown>")'")
        do {
            try await manager.removeFromPreferences()
        } catch {
            Log.error("Failed to remove orphaned tunnel: \(error)")
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
}
