#if DEBUG && !targetEnvironment(simulator)
import Foundation
import NetworkExtension
import SplitGuardCore

extension DebugVerificationNetworkChecks {
    static func runDeviceQuirk1(
        store: TunnelStore,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome {
        if let activeName = await activeNonProbeTunnelName() {
            return activeTunnelSkipOutcome(
                checkID: .quirk1ActiveTunnelSave, activeName: activeName,
                reason: "run self-contained Quirk #1 probe", start: start, clock: clock
            )
        }
        guard let fixture = DebugBundledFixtures.serverTest() else {
            return quirk1InfoOutcome(
                summary: "ServerTest.conf fixture required",
                detail: "Rebuild Debug with docs/ServerTest.conf to auto-probe Quirk #1 safely.",
                start: start,
                clock: clock
            )
        }
        return await executeAutomatedQuirk1(fixture: fixture, store: store, start: start, clock: clock)
    }

    static func runDeviceQuirk2(
        store: TunnelStore,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome {
        if let activeName = await activeNonProbeTunnelName() {
            return activeTunnelSkipOutcome(
                checkID: .quirk2AddOnDemandRunning, activeName: activeName,
                reason: "run self-contained Quirk #2 probe", start: start, clock: clock
            )
        }
        guard let fixture = DebugBundledFixtures.testCert() else {
            return NetworkCheckOutcome(
                result: AutomatedCheckResult(
                    id: .quirk2AddOnDemandRunning,
                    status: .info,
                    summary: "TestCert.conf fixture required",
                    detail: "Rebuild Debug with docs/TestCert.conf to auto-probe Quirk #2 safely.",
                    durationMilliseconds: durationMs(since: start, clock: clock)
                )
            )
        }
        return await executeAutomatedQuirk2(fixture: fixture, store: store, start: start, clock: clock)
    }
}

private extension DebugVerificationNetworkChecks {
    static func executeAutomatedQuirk1(
        fixture: DebugBundledFixture,
        store: TunnelStore,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome {
        await store.backend.setConfigurationChangeObservationPaused(true)
        let profileStore = ProfileStore()
        var tempManagers: [NETunnelProviderManager] = []

        do {
            let suffix = String(UUID().uuidString.prefix(5))
            let liveMgr = try await createFixtureManager(
                fixture: fixture,
                name: "\(probeNamePrefix)Q1LIVE_\(suffix)",
                profileStore: profileStore
            )
            tempManagers.append(liveMgr)
            try await startManagerAndAwaitConnected(liveMgr)

            let recorder = StatusTransitionRecorder(connection: liveMgr.connection)
            defer { recorder.stop() }
            let secondMgr = try await createTempManager(name: "\(probeNamePrefix)Q1NEW_\(suffix)", profileStore: profileStore)
            tempManagers.append(secondMgr)
            try? await Task.sleep(for: .seconds(2))

            let statusAfterSave = liveMgr.connection.status
            let transitions = recorder.recordedLabels()
            await cleanupManagers(tempManagers, profileStore: profileStore, store: store)

            let deactivated = statusAfterSave != .connected
                || transitions.contains("disconnected") || transitions.contains("disconnecting")
            let transitionText = transitions.isEmpty ? "none" : transitions.joined(separator: " -> ")
            let obs = "Saved new config while live ServerTest was connected. Post-save=\(statusLabel(statusAfterSave)), "
                + "transitions=\(transitionText)."
            let finding = IOSQuirkFinding(
                id: .saveNewDeactivatesActive,
                status: deactivated ? .reproduced : .notReproduced,
                observation: obs
            )
            return makeQuirkOutcome(
                checkID: .quirk1ActiveTunnelSave,
                finding: finding,
                summary: "\(deactivated ? "Reproduced" : "Not Reproduced") (post-save: \(statusLabel(statusAfterSave)))",
                elapsedMs: durationMs(since: start, clock: clock)
            )
        } catch {
            await cleanupManagers(tempManagers, profileStore: profileStore, store: store)
            return failedOutcome(
                id: .quirk1ActiveTunnelSave, summary: error.localizedDescription,
                detail: String(describing: error), start: start, clock: clock
            )
        }
    }

    static func executeAutomatedQuirk2(
        fixture: DebugBundledFixture,
        store: TunnelStore,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome {
        await store.backend.setConfigurationChangeObservationPaused(true)
        let profileStore = ProfileStore()
        var liveMgr: NETunnelProviderManager?

        do {
            let suffix = String(UUID().uuidString.prefix(5))
            let mgr = try await createFixtureManager(
                fixture: fixture,
                name: "\(probeNamePrefix)Q2LIVE_\(suffix)",
                profileStore: profileStore
            )
            liveMgr = mgr
            try await startManagerAndAwaitConnected(mgr)

            let recorder = StatusTransitionRecorder(connection: mgr.connection)
            defer { recorder.stop() }
            let policy = OnDemandPolicy(cellular: false, wifi: true, ssidFilter: .only(["__SG_NONEXISTENT_SSID__"]))
            policy.apply(to: mgr)
            mgr.isOnDemandEnabled = true
            var directSaveError: String?
            do {
                try await mgr.saveToPreferences()
            } catch {
                directSaveError = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(2))
            let statusAfter = mgr.connection.status
            let transitions = recorder.recordedLabels()

            await cleanupOnDemandTempManager(mgr, profileStore: profileStore, store: store)
            let reproduced = directSaveError != nil || statusAfter != .connected
            let eventsText = transitions.isEmpty ? "none" : transitions.joined(separator: " -> ")
            let obs = "Added on-demand to running TestCert without stopping. saveError=\(directSaveError ?? "none"), "
                + "postStatus=\(statusLabel(statusAfter)), events=\(eventsText)."
            let finding = IOSQuirkFinding(
                id: .onDemandOnRunningNeedsStop,
                status: reproduced ? .reproduced : .notReproduced,
                observation: obs
            )
            return makeQuirkOutcome(
                checkID: .quirk2AddOnDemandRunning,
                finding: finding,
                summary: "\(reproduced ? "Reproduced" : "Not Reproduced") (postStatus=\(statusLabel(statusAfter)))",
                elapsedMs: durationMs(since: start, clock: clock)
            )
        } catch {
            await cleanupOnDemandTempManager(liveMgr, profileStore: profileStore, store: store)
            return failedOutcome(
                id: .quirk2AddOnDemandRunning, summary: error.localizedDescription,
                detail: String(describing: error), start: start, clock: clock
            )
        }
    }

    static func createFixtureManager(
        fixture: DebugBundledFixture,
        name: String,
        profileStore: ProfileStore
    ) async throws -> NETunnelProviderManager {
        let profile = try DebugBundledFixtures.parsedProfile(for: fixture, named: name)
        let proto = try profileStore.makeProtocol(for: profile, providerBundleIdentifier: providerBundleID)
        let manager = NETunnelProviderManager()
        manager.localizedDescription = name
        manager.protocolConfiguration = proto
        manager.isEnabled = true
        manager.isOnDemandEnabled = false
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        return manager
    }

    static func startManagerAndAwaitConnected(_ manager: NETunnelProviderManager) async throws {
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw NSError(domain: "Verify", code: 20, userInfo: [NSLocalizedDescriptionKey: "Missing NETunnelProviderSession"])
        }
        try session.startTunnel(options: ["startedByApp": NSNumber(value: true)])
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if manager.connection.status == .connected { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
        throw NSError(
            domain: "Verify",
            code: 21,
            userInfo: [NSLocalizedDescriptionKey: "Live probe tunnel did not connect (status=\(statusLabel(manager.connection.status)))."]
        )
    }
}
#endif
