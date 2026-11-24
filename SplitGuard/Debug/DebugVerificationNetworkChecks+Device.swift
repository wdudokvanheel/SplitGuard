#if DEBUG && !targetEnvironment(simulator)
import Foundation
import NetworkExtension
import SplitGuardCore

extension DebugVerificationNetworkChecks {
    static func runDeviceCRUDCheck(
        store: TunnelStore,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome {
        await store.backend.setConfigurationChangeObservationPaused(true)
        let profileStore = ProfileStore()
        var tempManagers: [NETunnelProviderManager] = []

        do {
            let suffix = String(UUID().uuidString.prefix(6))
            let name10 = "\(probeNamePrefix)wg10_\(suffix)"
            let name2 = "\(probeNamePrefix)wg2_\(suffix)"
            let renamed2 = "\(probeNamePrefix)wg2_renamed_\(suffix)"

            let manager10 = try await createTempManager(name: name10, profileStore: profileStore)
            tempManagers.append(manager10)
            let manager2 = try await createTempManager(name: name2, profileStore: profileStore)
            tempManagers.append(manager2)

            let sortedProbeNames = try await NETunnelProviderManager.loadAllFromPreferences()
                .compactMap(\.localizedDescription)
                .filter { $0 == name10 || $0 == name2 }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            guard sortedProbeNames == [name2, name10] else {
                await cleanupManagers(tempManagers, profileStore: profileStore, store: store)
                return failedOutcome(
                    id: .neManagerCrudAndSort,
                    summary: "Reloaded probe managers did not match expected natural sort order",
                    detail: "Found: \(sortedProbeNames.joined(separator: ", "))",
                    start: start,
                    clock: clock
                )
            }

            manager2.localizedDescription = renamed2
            try await manager2.saveToPreferences()
            let foundRenamed = try await NETunnelProviderManager.loadAllFromPreferences()
                .contains { $0.localizedDescription == renamed2 }
            await cleanupManagers(tempManagers, profileStore: profileStore, store: store)

            return try await finalizeCRUDOutcome(
                foundRenamed: foundRenamed,
                name10: name10,
                name2: name2,
                renamed2: renamed2,
                start: start,
                clock: clock
            )
        } catch {
            await cleanupManagers(tempManagers, profileStore: profileStore, store: store)
            return failedOutcome(
                id: .neManagerCrudAndSort,
                summary: error.localizedDescription,
                detail: String(describing: error),
                start: start,
                clock: clock
            )
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func finalizeCRUDOutcome(
        foundRenamed: Bool,
        name10: String,
        name2: String,
        renamed2: String,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async throws -> NetworkCheckOutcome {
        let leaked = try await NETunnelProviderManager.loadAllFromPreferences()
            .contains { $0.localizedDescription == name10 || $0.localizedDescription == renamed2 }
        guard foundRenamed && !leaked else {
            return failedOutcome(
                id: .neManagerCrudAndSort,
                summary: "Rename or cleanup check failed",
                detail: "foundRenamed=\(foundRenamed), leakedAfterCleanup=\(leaked)",
                start: start,
                clock: clock
            )
        }
        let detail = [
            "Created 2 temporary managers (\(name10), \(name2)); natural sort verified.",
            "Rename to \(renamed2) persisted across loadAllFromPreferences().",
            "Both temporary managers and keychain items cleanly deleted."
        ].joined(separator: "\n")
        return NetworkCheckOutcome(
            result: AutomatedCheckResult(
                id: .neManagerCrudAndSort,
                status: .passed,
                summary: "NETunnelProviderManager create/load/sort/rename/delete passed",
                detail: detail,
                durationMilliseconds: durationMs(since: start, clock: clock)
            )
        )
    }

    static func runDeviceStartErrorProbe(
        store: TunnelStore,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome {
        if let activeName = await activeNonProbeTunnelName() {
            return skippedStartErrorOutcome(activeName: activeName, start: start, clock: clock)
        }

        await store.backend.setConfigurationChangeObservationPaused(true)
        let profileStore = ProfileStore()
        var tempManager: NETunnelProviderManager?

        do {
            let suffix = String(UUID().uuidString.prefix(6))
            let manager = try await createTempManager(
                name: "\(probeNamePrefix)ERR_\(suffix)",
                endpoint: "nonexistent-verify-probe.invalid:51820",
                profileStore: profileStore
            )
            tempManager = manager
            try await manager.loadFromPreferences()

            let probeData = try await executeStartErrorSessionProbe(manager: manager)
            await cleanupManagers([manager], profileStore: profileStore, store: store)
            return buildStartErrorOutcome(probeData: probeData, start: start, clock: clock)
        } catch {
            if let mgr = tempManager {
                await cleanupManagers([mgr], profileStore: profileStore, store: store)
            } else {
                await store.backend.setConfigurationChangeObservationPaused(false)
                await store.reloadFromBackend()
            }
            return failedOutcome(
                id: .startErrorProbe,
                summary: "Probe failed: \(error.localizedDescription)",
                detail: String(describing: error),
                start: start,
                clock: clock
            )
        }
    }

    static func activeNonProbeTunnelName() async -> String? {
        guard let managers = try? await NETunnelProviderManager.loadAllFromPreferences() else { return nil }
        for manager in managers {
            let name = manager.localizedDescription ?? ""
            guard !name.hasPrefix(probeNamePrefix) else { continue }
            let status = manager.connection.status
            if status == .connected || status == .connecting || status == .reasserting {
                return name.isEmpty ? "Unnamed Tunnel" : name
            }
        }
        return nil
    }

    static func createTempManager(
        name: String,
        endpoint: String = "198.51.100.10:51820",
        profileStore: ProfileStore
    ) async throws -> NETunnelProviderManager {
        let profile = try DebugVerificationCoreChecks.makeFullSampleProfile(name: name, endpoint: endpoint)
        let proto = try profileStore.makeProtocol(for: profile, providerBundleIdentifier: providerBundleID)
        let manager = NETunnelProviderManager()
        manager.localizedDescription = name
        manager.protocolConfiguration = proto
        manager.isEnabled = true
        manager.isOnDemandEnabled = false
        try await manager.saveToPreferences()
        return manager
    }

    static func removeTempManager(_ manager: NETunnelProviderManager, profileStore: ProfileStore) async {
        let ref = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference
        try? await manager.removeFromPreferences()
        if let ref {
            profileStore.delete(reference: ref)
        }
    }

    static func cleanupManagers(
        _ managers: [NETunnelProviderManager],
        profileStore: ProfileStore,
        store: TunnelStore
    ) async {
        for manager in managers {
            (manager.connection as? NETunnelProviderSession)?.stopTunnel()
            await removeTempManager(manager, profileStore: profileStore)
        }
        await store.backend.setConfigurationChangeObservationPaused(false)
        await store.reloadFromBackend()
    }

    static func failedOutcome(
        id: AutomatedCheckID,
        summary: String,
        detail: String,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> NetworkCheckOutcome {
        NetworkCheckOutcome(
            result: AutomatedCheckResult(
                id: id,
                status: .failed,
                summary: summary,
                detail: detail,
                durationMilliseconds: durationMs(since: start, clock: clock)
            )
        )
    }

    static func statusLabel(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}

private struct StartErrorProbeCapture {
    let reachedDisconnected: Bool
    let transitions: [String]
    let rawDisconnectDesc: String
    let decodedDisconnect: TunnelStartError?
    let ipcRaw: String
    let ipcDecoded: TunnelStartError?
}

private extension DebugVerificationNetworkChecks {
    static func executeStartErrorSessionProbe(manager: NETunnelProviderManager) async throws -> StartErrorProbeCapture {
        let observer = StatusTransitionRecorder(connection: manager.connection)
        defer { observer.stop() }
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw NSError(domain: "Verify", code: 10, userInfo: [NSLocalizedDescriptionKey: "Missing NETunnelProviderSession"])
        }
        try session.startTunnel(options: ["startedByApp": NSNumber(value: true)])
        let reachedDisconnected = await observer.waitForDisconnect(timeout: .seconds(12))
        let transitions = observer.recordedLabels()

        let disconnectErr = await fetchDisconnectError(from: manager.connection)
        let rawDisconnectDesc: String
        let decodedDisconnect: TunnelStartError?
        if let nsErr = disconnectErr as NSError? {
            rawDisconnectDesc = "\(nsErr.domain) code=\(nsErr.code): \(nsErr.localizedDescription)"
            decodedDisconnect = TunnelStartError(nsError: nsErr)
        } else {
            rawDisconnectDesc = "nil"
            decodedDisconnect = nil
        }
        let ipcResult = await sendLastStartErrorIPC(to: session)
        return StartErrorProbeCapture(
            reachedDisconnected: reachedDisconnected,
            transitions: transitions,
            rawDisconnectDesc: rawDisconnectDesc,
            decodedDisconnect: decodedDisconnect,
            ipcRaw: ipcResult.rawDescription,
            ipcDecoded: ipcResult.decoded
        )
    }

    static func buildStartErrorOutcome(
        probeData: StartErrorProbeCapture,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> NetworkCheckOutcome {
        let verdictLine = buildStartErrorVerdict(
            disconnectDecoded: probeData.decodedDisconnect,
            ipcDecoded: probeData.ipcDecoded
        )
        let summary = StartErrorProbeSummary(
            fetchLastDisconnectRaw: probeData.rawDisconnectDesc,
            fetchLastDisconnectDecoded: probeData.decodedDisconnect.map { "\($0.title): \($0.message)" },
            ipcReply: probeData.ipcRaw,
            ipcDecoded: probeData.ipcDecoded.map { "\($0.title): \($0.message)" },
            statusTransitions: probeData.transitions,
            verdictLine: verdictLine
        )
        let quirk5Status: QuirkObservationStatus = (probeData.reachedDisconnected && probeData.transitions.contains("connecting"))
            ? .notReproduced
            : .reproduced
        let transitionText = probeData.transitions.isEmpty ? "none" : probeData.transitions.joined(separator: " -> ")
        let isExpectedDNSFailure: (TunnelStartError?) -> Bool = { error in
            if case .dnsResolutionFailed = error { return true }
            return false
        }
        let didDeliver = isExpectedDNSFailure(probeData.decodedDisconnect)
            || isExpectedDNSFailure(probeData.ipcDecoded)
        let detail = [
            verdictLine,
            "fetchLastDisconnectError raw: \(probeData.rawDisconnectDesc)",
            "fetchLastDisconnectError decoded: \(summary.fetchLastDisconnectDecoded ?? "nil")",
            "IPC ProviderMessage.lastStartError: \(probeData.ipcRaw)",
            "Transitions: \(transitionText) (disconnected=\(probeData.reachedDisconnected))"
        ].joined(separator: "\n")

        return NetworkCheckOutcome(
            result: AutomatedCheckResult(
                id: .startErrorProbe,
                status: didDeliver ? .passed : .failed,
                summary: verdictLine,
                detail: detail,
                durationMilliseconds: durationMs(since: start, clock: clock)
            ),
            updatedQuirks: [
                IOSQuirkFinding(
                    id: .missingStatusNotifications,
                    status: quirk5Status,
                    observation: "Observed NEVPNStatusDidChange sequence: \(transitionText)"
                )
            ],
            startErrorSummary: summary
        )
    }

    static func skippedStartErrorOutcome(
        activeName: String,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> NetworkCheckOutcome {
        let msg = "Skipped because '\(activeName)' is currently active. Disconnect it and re-run to probe safely."
        let summary = StartErrorProbeSummary(
            fetchLastDisconnectRaw: "Skipped (active tunnel)",
            fetchLastDisconnectDecoded: nil,
            ipcReply: "Skipped",
            ipcDecoded: nil,
            statusTransitions: [],
            verdictLine: msg
        )
        return NetworkCheckOutcome(
            result: AutomatedCheckResult(
                id: .startErrorProbe,
                status: .info,
                summary: "Skipped while '\(activeName)' is active",
                detail: msg,
                durationMilliseconds: durationMs(since: start, clock: clock)
            ),
            startErrorSummary: summary
        )
    }

    static func fetchDisconnectError(from connection: NEVPNConnection) async -> Error? {
        await withCheckedContinuation { continuation in
            connection.fetchLastDisconnectError { error in
                continuation.resume(returning: error)
            }
        }
    }

    static func sendLastStartErrorIPC(
        to session: NETunnelProviderSession
    ) async -> (rawDescription: String, decoded: TunnelStartError?) {
        guard let payload = try? ProviderMessage.lastStartError.encode() else {
            return ("Failed to encode ProviderMessage.lastStartError", nil)
        }
        let data: Data? = await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(payload) { reply in
                    continuation.resume(returning: reply)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
        guard let data else {
            return ("No IPC reply (extension not running after failed start)", nil)
        }
        guard let reply = try? ProviderReply.decode(from: data) else {
            return ("Undecodable reply (\(data.count) bytes)", nil)
        }
        if case .lastStartError(let startError) = reply {
            return (startError.map { "Delivered: \($0.title)" } ?? "Delivered: nil", startError)
        }
        return ("Unexpected reply variant", nil)
    }

    static func buildStartErrorVerdict(
        disconnectDecoded: TunnelStartError?,
        ipcDecoded: TunnelStartError?
    ) -> String {
        switch (disconnectDecoded != nil, ipcDecoded != nil) {
        case (true, true):
            return "Delivered by BOTH fetchLastDisconnectError and IPC fallback."
        case (true, false):
            return "Delivered by NEVPNConnection.fetchLastDisconnectError (IPC fallback not needed)."
        case (false, true):
            return "fetchLastDisconnectError did NOT decode TunnelStartError; delivered by IPC fallback."
        case (false, false):
            return "NEITHER fetchLastDisconnectError nor IPC delivered TunnelStartError."
        }
    }
}

/// Use the real Keychain for CRUD, injecting exactly one inaccessible read.
private final class OneFailedRead: KeychainStore, @unchecked Sendable {
    let system = SystemKeychainStore()
    let lock = NSLock()
    private var pending = true

    func load(reference: Data) throws -> Data {
        let fail = lock.withLock {
            defer { pending = false }
            return pending
        }
        if fail { throw ProfileStoreError.keychainLoadFailed(errSecInteractionNotAllowed) }
        return try system.load(reference: reference)
    }

    func add(data: Data, label: String, account: String, service: String, description: String, accessGroup: String?) throws -> Data {
        try system.add(data: data, label: label, account: account, service: service, description: description, accessGroup: accessGroup)
    }

    func delete(reference: Data) { system.delete(reference: reference) }
    func exists(reference: Data) -> Bool { system.exists(reference: reference) }
    func allReferences(service: String, accessGroup: String?) -> [Data] { system.allReferences(service: service, accessGroup: accessGroup) }
}

extension DebugVerificationNetworkChecks {
    static func runDeviceProfileRecovery(store: TunnelStore) async -> NetworkCheckOutcome {
        let id = AutomatedCheckID.transientProfileRead
        let start = ContinuousClock.now
        if let name = await activeNonProbeTunnelName() {
            return NetworkCheckOutcome(result: AutomatedCheckResult(id: id, status: .info, summary: "Active user tunnel: \(name)"))
        }
        let name = probeNamePrefix + UUID().uuidString
        let storage = ProfileStore(keychain: OneFailedRead(), service: name, accessGroup: AppGroup.identifier())
        var created: NETunnelProviderManager?
        await store.backend.setConfigurationChangeObservationPaused(true)
        let result: AutomatedCheckResult
        do {
            let manager = try await createTempManager(name: name, profileStore: storage)
            created = manager
            guard let ref = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference else {
                throw LiveCheckError("Disposable manager has no password reference")
            }
            let backend = SystemTunnelBackend(profileStore: storage) {
                try await NETunnelProviderManager.loadAllFromPreferences().filter {
                    $0.localizedDescription == name && ($0.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference == ref
                }
            }
            _ = try await backend.loadAll()
            let retry = try await backend.loadAll()
            guard retry.count == 1, let recovered = retry.first,
                  recovered.profile == (try storage.load(reference: ref, name: name)) else {
                throw LiveCheckError("Second reload could not recover the original manager and reference")
            }
            result = AutomatedCheckResult(id: id, status: .passed, summary: "Recovered original manager, reference and profile on retry",
                                          durationMilliseconds: durationMs(since: start, clock: ContinuousClock()))
        } catch {
            result = AutomatedCheckResult(id: id, status: .failed, summary: error.localizedDescription)
        }
        await cleanupManagers([created].compactMap { $0 }, profileStore: storage, store: store)
        // Covers a failed preference save after Keychain insertion. This service belongs only to this run.
        storage.deleteOrphaned(keeping: [])
        return NetworkCheckOutcome(result: result)
    }
}
#endif
