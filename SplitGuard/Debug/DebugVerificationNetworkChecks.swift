#if DEBUG
import Foundation
import NetworkExtension
import SplitGuardCore
import WireGuardEngine

struct NetworkCheckOutcome: Sendable {
    let result: AutomatedCheckResult
    var updatedQuirks: [IOSQuirkFinding] = []
    var startErrorSummary: StartErrorProbeSummary?
}

enum DebugVerificationNetworkChecks {
    static let probeNamePrefix = "__SG_VERIFY_"
    static let manualFailingTunnelName = "__SG_VERIFY_FAIL_TEST"

    static var providerBundleID: String {
        (Bundle.main.bundleIdentifier ?? "com.bitechular.splitguard") + ".network-extension"
    }

    static func runProfileRecovery(store: TunnelStore) async -> NetworkCheckOutcome {
        #if !targetEnvironment(simulator)
        if store.backend is SystemTunnelBackend {
            return await runDeviceProfileRecovery(store: store)
        }
        #endif
        return NetworkCheckOutcome(result: AutomatedCheckResult(id: .transientProfileRead, status: .info,
                                                                 summary: "Requires device VPN preferences and Keychain"))
    }

    static func runManagerCRUDAndSortCheck(store: TunnelStore) async -> NetworkCheckOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        #if !targetEnvironment(simulator)
        if store.backend is SystemTunnelBackend {
            return await runDeviceCRUDCheck(store: store, start: start, clock: clock)
        }
        #endif
        return await runSimulatorCRUDCheck(start: start, clock: clock)
    }

    static func runStartErrorProbe(store: TunnelStore) async -> NetworkCheckOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        #if !targetEnvironment(simulator)
        if store.backend is SystemTunnelBackend {
            return await runDeviceStartErrorProbe(store: store, start: start, clock: clock)
        }
        #endif
        return simulatorStartErrorOutcome(start: start, clock: clock)
    }

    static func runQuirk6BulkSaveCheck(store: TunnelStore) async -> NetworkCheckOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        #if !targetEnvironment(simulator)
        if store.backend is SystemTunnelBackend {
            return await runDeviceQuirk6(store: store, start: start, clock: clock)
        }
        #endif
        return simulatorQuirkOutcome(
            checkID: .quirk6BulkSaveNotifications,
            quirkID: .bulkSaveNotificationPerItem,
            start: start,
            clock: clock
        )
    }

    static func runQuirk4FreshStartAndEnabledCheck(store: TunnelStore) async -> NetworkCheckOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        #if !targetEnvironment(simulator)
        if store.backend is SystemTunnelBackend {
            return await runDeviceQuirk4(store: store, start: start, clock: clock)
        }
        #endif
        return simulatorQuirkOutcome(
            checkID: .quirk4FreshStartAndEnabled,
            quirkID: .startStaleOrDisabledManager,
            start: start,
            clock: clock
        )
    }

    static func runQuirk3OnDemandReloadCheck(store: TunnelStore) async -> NetworkCheckOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        #if !targetEnvironment(simulator)
        if store.backend is SystemTunnelBackend {
            return await runDeviceQuirk3(store: store, start: start, clock: clock)
        }
        #endif
        return simulatorQuirkOutcome(
            checkID: .quirk3OnDemandReload,
            quirkID: .enableOnDemandNeedsReload,
            start: start,
            clock: clock
        )
    }

    static func runQuirk1ActiveTunnelSaveCheck(store: TunnelStore) async -> NetworkCheckOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        #if !targetEnvironment(simulator)
        if store.backend is SystemTunnelBackend {
            return await runDeviceQuirk1(store: store, start: start, clock: clock)
        }
        #endif
        return simulatorQuirkOutcome(
            checkID: .quirk1ActiveTunnelSave,
            quirkID: .saveNewDeactivatesActive,
            start: start,
            clock: clock
        )
    }

    static func runQuirk2AddOnDemandRunningCheck(store: TunnelStore) async -> NetworkCheckOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        #if !targetEnvironment(simulator)
        if store.backend is SystemTunnelBackend {
            return await runDeviceQuirk2(store: store, start: start, clock: clock)
        }
        #endif
        return simulatorQuirkOutcome(
            checkID: .quirk2AddOnDemandRunning,
            quirkID: .onDemandOnRunningNeedsStop,
            start: start,
            clock: clock
        )
    }

    @discardableResult
    static func cleanupAllProbeManagers(store: TunnelStore) async -> Int {
        #if targetEnvironment(simulator)
        return 0
        #else
        await store.backend.setConfigurationChangeObservationPaused(true)
        let profileStore = ProfileStore()
        var removedCount = 0
        if let managers = try? await NETunnelProviderManager.loadAllFromPreferences() {
            for manager in managers {
                let name = manager.localizedDescription ?? ""
                guard name.hasPrefix(probeNamePrefix), name != manualFailingTunnelName else { continue }
                await removeTempManager(manager, profileStore: profileStore)
                removedCount += 1
            }
        }
        await store.backend.setConfigurationChangeObservationPaused(false)
        await store.reloadFromBackend()
        return removedCount
        #endif
    }

    @MainActor
    static func createManualFailingTunnel(in store: TunnelStore) async throws -> Tunnel {
        if let existing = store.tunnel(named: manualFailingTunnelName) {
            return existing
        }
        let profile = try DebugVerificationCoreChecks.makeFullSampleProfile(
            name: manualFailingTunnelName,
            endpoint: "nonexistent-verify-probe.invalid:51820"
        )
        return try await store.addTunnel(profile, onDemandPolicy: .off)
    }

    @MainActor
    static func removeManualFailingTunnel(in store: TunnelStore) async -> Bool {
        guard let existing = store.tunnel(named: manualFailingTunnelName) else {
            return true
        }
        return await store.delete(tunnel: existing)
    }

    static func durationMs(since start: ContinuousClock.Instant, clock: ContinuousClock) -> Int {
        let duration = start.duration(to: clock.now)
        let secondsMs = Int(duration.components.seconds) * 1000
        let attoMs = Int(duration.components.attoseconds / 1_000_000_000_000_000)
        return max(0, secondsMs + attoMs)
    }
}

private extension DebugVerificationNetworkChecks {
    static func runSimulatorCRUDCheck(
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome {
        do {
            let backend = InMemoryTunnelBackend()
            let profile10 = try DebugVerificationCoreChecks.makeFullSampleProfile(name: "\(probeNamePrefix)t10")
            let profile2 = try DebugVerificationCoreChecks.makeFullSampleProfile(name: "\(probeNamePrefix)t2")
            let record10 = try await backend.save(profile10, onDemandPolicy: .off, isOnDemandEnabled: false, replacing: nil)
            let record2 = try await backend.save(profile2, onDemandPolicy: .off, isOnDemandEnabled: false, replacing: nil)
            let names = try await backend.loadAll().map(\.profile.name)
            guard names == ["\(probeNamePrefix)t2", "\(probeNamePrefix)t10"] else {
                throw NSError(domain: "Verify", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sort order mismatch: \(names)"])
            }
            var renamed = profile2
            renamed.name = "\(probeNamePrefix)t2_renamed"
            _ = try await backend.save(renamed, onDemandPolicy: .off, isOnDemandEnabled: false, replacing: record2.id)
            try await backend.remove(id: record2.id)
            try await backend.remove(id: record10.id)
            let remaining = try await backend.loadAll()
            guard remaining.isEmpty else {
                throw NSError(domain: "Verify", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cleanup left \(remaining.count) items"])
            }
            return NetworkCheckOutcome(
                result: AutomatedCheckResult(
                    id: .neManagerCrudAndSort,
                    status: .info,
                    summary: "Simulator: verified via InMemoryTunnelBackend (run on device for NetworkExtension)",
                    detail: "CRUD, rename, natural sort (t2 < t10), and delete passed on InMemoryTunnelBackend.",
                    durationMilliseconds: durationMs(since: start, clock: clock)
                )
            )
        } catch {
            return NetworkCheckOutcome(
                result: AutomatedCheckResult(
                    id: .neManagerCrudAndSort,
                    status: .failed,
                    summary: error.localizedDescription,
                    detail: String(describing: error),
                    durationMilliseconds: durationMs(since: start, clock: clock)
                )
            )
        }
    }

    static func simulatorStartErrorOutcome(
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> NetworkCheckOutcome {
        let summary = StartErrorProbeSummary(
            fetchLastDisconnectRaw: "N/A (Simulator)",
            fetchLastDisconnectDecoded: nil,
            ipcReply: "N/A (Simulator)",
            ipcDecoded: nil,
            statusTransitions: [],
            verdictLine: "Simulator cannot run NEPacketTunnelProvider; run on physical iOS 26 device."
        )
        return NetworkCheckOutcome(
            result: AutomatedCheckResult(
                id: .startErrorProbe,
                status: .info,
                summary: "Physical device required for PacketTunnelProvider start-error probe",
                detail: summary.verdictLine,
                durationMilliseconds: durationMs(since: start, clock: clock)
            ),
            updatedQuirks: [
                IOSQuirkFinding(
                    id: .missingStatusNotifications,
                    status: .simulatorOnly,
                    observation: "Requires physical device NEVPNStatusDidChange delivery."
                )
            ],
            startErrorSummary: summary
        )
    }

    static func simulatorQuirkOutcome(
        checkID: AutomatedCheckID,
        quirkID: IOSQuirkID,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> NetworkCheckOutcome {
        NetworkCheckOutcome(
            result: AutomatedCheckResult(
                id: checkID,
                status: .info,
                summary: "Physical iOS 26 device required",
                detail: "NetworkExtension preferences are unavailable on the iOS Simulator.",
                durationMilliseconds: durationMs(since: start, clock: clock)
            ),
            updatedQuirks: [
                IOSQuirkFinding(id: quirkID, status: .simulatorOnly, observation: "Requires physical iOS 26 device.")
            ]
        )
    }
}

#if !targetEnvironment(simulator)
final class StatusTransitionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [String] = []
    private var sawConnecting = false
    private var sawDisconnectAfterConnect = false
    private var token: NSObjectProtocol?

    init(connection: NEVPNConnection) {
        token = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: nil
        ) { [weak self] notification in
            guard let self, let conn = notification.object as? NEVPNConnection else { return }
            let status = conn.status
            let label = DebugVerificationNetworkChecks.statusLabel(status)
            self.lock.withLock {
                self.labels.append(label)
                if status == .connecting || status == .connected {
                    self.sawConnecting = true
                }
                if (status == .disconnected || status == .invalid) && self.sawConnecting {
                    self.sawDisconnectAfterConnect = true
                }
            }
        }
    }

    func waitForDisconnect(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if lock.withLock({ sawDisconnectAfterConnect }) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return lock.withLock { sawDisconnectAfterConnect }
    }

    func recordedLabels() -> [String] { lock.withLock { labels } }

    func stop() {
        let current = lock.withLock { () -> NSObjectProtocol? in
            defer { token = nil }
            return token
        }
        if let current { NotificationCenter.default.removeObserver(current) }
    }
}

final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var token: NSObjectProtocol?

    init(name: Notification.Name) {
        token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.value += 1 }
        }
    }

    func count() -> Int { lock.withLock { value } }
    func reset() { lock.withLock { value = 0 } }

    func stop() {
        let current = lock.withLock { () -> NSObjectProtocol? in
            defer { token = nil }
            return token
        }
        if let current { NotificationCenter.default.removeObserver(current) }
    }
}
#endif
#endif
