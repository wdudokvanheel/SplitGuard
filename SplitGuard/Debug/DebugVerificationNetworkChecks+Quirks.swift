#if DEBUG && !targetEnvironment(simulator)
import Foundation
import NetworkExtension
import SplitGuardCore

extension DebugVerificationNetworkChecks {
    static func runDeviceQuirk6(
        store: TunnelStore,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome {
        await store.backend.setConfigurationChangeObservationPaused(true)
        let profileStore = ProfileStore()
        var tempManagers: [NETunnelProviderManager] = []
        let counter = NotificationCounter(name: .NEVPNConfigurationChange)
        defer { counter.stop() }

        do {
            let suffix = String(UUID().uuidString.prefix(6))
            for idx in 1...3 {
                let mgr = try await createTempManager(name: "\(probeNamePrefix)Q6_\(idx)_\(suffix)", profileStore: profileStore)
                tempManagers.append(mgr)
            }
            try? await Task.sleep(for: .milliseconds(750))
            let saveCount = counter.count()

            counter.reset()
            for mgr in tempManagers {
                await removeTempManager(mgr, profileStore: profileStore)
            }
            try? await Task.sleep(for: .milliseconds(750))
            let removeCount = counter.count()

            await store.backend.setConfigurationChangeObservationPaused(false)
            await store.reloadFromBackend()

            let reproduced = saveCount >= 2 || removeCount >= 2
            let obs = "3 saves fired \(saveCount) NEVPNConfigurationChange notification(s); 3 removals fired \(removeCount)."
            let finding = IOSQuirkFinding(
                id: .bulkSaveNotificationPerItem,
                status: reproduced ? .reproduced : .notReproduced,
                observation: obs
            )
            return makeQuirkOutcome(
                checkID: .quirk6BulkSaveNotifications,
                finding: finding,
                summary: "\(reproduced ? "Reproduced" : "Not Reproduced"): \(saveCount) save / \(removeCount) remove events",
                elapsedMs: durationMs(since: start, clock: clock)
            )
        } catch {
            await cleanupManagers(tempManagers, profileStore: profileStore, store: store)
            return failedOutcome(
                id: .quirk6BulkSaveNotifications,
                summary: error.localizedDescription,
                detail: String(describing: error),
                start: start,
                clock: clock
            )
        }
    }

    static func runDeviceQuirk4(
        store: TunnelStore,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome {
        if let activeName = await activeNonProbeTunnelName() {
            return activeTunnelSkipOutcome(
                checkID: .quirk4FreshStartAndEnabled,
                activeName: activeName,
                reason: "probe fresh startTunnel safely",
                start: start,
                clock: clock
            )
        }

        await store.backend.setConfigurationChangeObservationPaused(true)
        let profileStore = ProfileStore()
        var tempManagers: [NETunnelProviderManager] = []

        do {
            let suffix = String(UUID().uuidString.prefix(6))
            let mgrA = try await createTempManager(
                name: "\(probeNamePrefix)Q4A_\(suffix)",
                endpoint: "nonexistent-verify-probe.invalid:51820",
                profileStore: profileStore
            )
            tempManagers.append(mgrA)

            let (hitStaleOrInvalid, immediateStartOutcome) = probeImmediateStart(manager: mgrA)
            let mgrB = try await createTempManager(name: "\(probeNamePrefix)Q4B_\(suffix)", profileStore: profileStore)
            tempManagers.append(mgrB)
            try await mgrA.loadFromPreferences()
            let becameDisabled = !mgrA.isEnabled
            await cleanupManagers(tempManagers, profileStore: profileStore, store: store)

            let reproduced = hitStaleOrInvalid || becameDisabled
            let obs = "Fresh start without reload: \(immediateStartOutcome). Saving 2nd manager disabled 1st: \(becameDisabled)."
            let finding = IOSQuirkFinding(
                id: .startStaleOrDisabledManager,
                status: reproduced ? .reproduced : .notReproduced,
                observation: obs
            )
            return makeQuirkOutcome(
                checkID: .quirk4FreshStartAndEnabled,
                finding: finding,
                summary: "\(reproduced ? "Reproduced" : "Not Reproduced") (stale=\(hitStaleOrInvalid), disabled=\(becameDisabled))",
                elapsedMs: durationMs(since: start, clock: clock)
            )
        } catch {
            await cleanupManagers(tempManagers, profileStore: profileStore, store: store)
            return failedOutcome(
                id: .quirk4FreshStartAndEnabled,
                summary: error.localizedDescription,
                detail: String(describing: error),
                start: start,
                clock: clock
            )
        }
    }

    static func runDeviceQuirk3(
        store: TunnelStore,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome {
        if let activeName = await activeNonProbeTunnelName() {
            return activeTunnelSkipOutcome(
                checkID: .quirk3OnDemandReload, activeName: activeName,
                reason: "probe on-demand reload safely", start: start, clock: clock
            )
        }

        await store.backend.setConfigurationChangeObservationPaused(true)
        let profileStore = ProfileStore()
        var tempManager: NETunnelProviderManager?

        do {
            let suffix = String(UUID().uuidString.prefix(6))
            let mgr = try await createTempManager(
                name: "\(probeNamePrefix)Q3_\(suffix)",
                endpoint: "nonexistent-verify-probe.invalid:51820",
                profileStore: profileStore
            )
            tempManager = mgr
            try await mgr.loadFromPreferences()

            let (startErr, transitions) = try await probeOnDemandWithoutReload(manager: mgr)
            await cleanupOnDemandTempManager(mgr, profileStore: profileStore, store: store)

            let reproduced = startErr != nil || transitions.isEmpty
            let eventsText = transitions.isEmpty ? "NONE" : transitions.joined(separator: " -> ")
            let obs = "Enabled on-demand without reload. startTunnel error: \(startErr ?? "none"). Events: \(eventsText)."
            let finding = IOSQuirkFinding(
                id: .enableOnDemandNeedsReload,
                status: reproduced ? .reproduced : .notReproduced,
                observation: obs
            )
            return makeQuirkOutcome(
                checkID: .quirk3OnDemandReload,
                finding: finding,
                summary: "\(reproduced ? "Reproduced" : "Not Reproduced") (events=\(transitions.count))",
                elapsedMs: durationMs(since: start, clock: clock)
            )
        } catch {
            await cleanupOnDemandTempManager(tempManager, profileStore: profileStore, store: store)
            return failedOutcome(
                id: .quirk3OnDemandReload, summary: error.localizedDescription,
                detail: String(describing: error), start: start, clock: clock
            )
        }
    }

    static func runDeviceQuirk1(
        store: TunnelStore,
        allowActiveTunnelInterruption: Bool,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        guard let activeMgr = managers.first(where: {
            let name = $0.localizedDescription ?? ""
            return !name.hasPrefix(probeNamePrefix) && $0.connection.status == .connected
        }) else {
            return quirk1InfoOutcome(
                summary: "Needs Active Tunnel",
                detail: "Needs Active Tunnel: connect a real tunnel first, enable the opt-in toggle, and re-run.",
                start: start,
                clock: clock
            )
        }

        let activeName = activeMgr.localizedDescription ?? "Active Tunnel"
        guard allowActiveTunnelInterruption else {
            let detail = "Active tunnel '\(activeName)' detected, but opt-in toggle is OFF. Enable toggle to test saving a new config."
            return quirk1InfoOutcome(summary: "Opt-in required (active: \(activeName))", detail: detail, start: start, clock: clock)
        }

        return await executeQuirk1Save(activeMgr: activeMgr, activeName: activeName, store: store, start: start, clock: clock)
    }
}

private extension DebugVerificationNetworkChecks {
    static func probeImmediateStart(manager: NETunnelProviderManager) -> (Bool, String) {
        do {
            try (manager.connection as? NETunnelProviderSession)?.startTunnel(options: nil)
            (manager.connection as? NETunnelProviderSession)?.stopTunnel()
            return (false, "startTunnel succeeded without prior loadFromPreferences()")
        } catch let vpnErr as NEVPNError
            where vpnErr.code == .configurationInvalid || vpnErr.code == .configurationStale {
            return (true, "Threw NEVPNError(\(vpnErr.code.rawValue)) without loadFromPreferences()")
        } catch {
            return (false, "Threw \(error.localizedDescription)")
        }
    }

    static func probeOnDemandWithoutReload(manager: NETunnelProviderManager) async throws -> (String?, [String]) {
        let policy = OnDemandPolicy(cellular: false, wifi: true, ssidFilter: .only(["__SG_NONEXISTENT_SSID__"]))
        policy.apply(to: manager)
        manager.isOnDemandEnabled = true
        manager.isEnabled = true
        try await manager.saveToPreferences()

        let recorder = StatusTransitionRecorder(connection: manager.connection)
        defer { recorder.stop() }
        var startError: String?
        do {
            try (manager.connection as? NETunnelProviderSession)?.startTunnel(options: ["startedByApp": NSNumber(value: true)])
        } catch {
            startError = error.localizedDescription
        }
        _ = await recorder.waitForDisconnect(timeout: .seconds(6))
        return (startError, recorder.recordedLabels())
    }

    static func executeQuirk1Save(
        activeMgr: NETunnelProviderManager,
        activeName: String,
        store: TunnelStore,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome {
        await store.backend.setConfigurationChangeObservationPaused(true)
        let profileStore = ProfileStore()
        var tempManager: NETunnelProviderManager?
        let recorder = StatusTransitionRecorder(connection: activeMgr.connection)
        defer { recorder.stop() }

        do {
            let suffix = String(UUID().uuidString.prefix(6))
            let created = try await createTempManager(name: "\(probeNamePrefix)Q1_\(suffix)", profileStore: profileStore)
            tempManager = created
            try? await Task.sleep(for: .seconds(2))

            let statusAfterSave = activeMgr.connection.status
            let transitions = recorder.recordedLabels()
            await cleanupManagers([created], profileStore: profileStore, store: store)

            let deactivated = statusAfterSave != .connected
                || transitions.contains("disconnected")
                || transitions.contains("disconnecting")
            let transitionText = transitions.isEmpty ? "none" : transitions.joined(separator: " -> ")
            let obs = "Saved new config while '\(activeName)' was connected. Post-save=\(statusLabel(statusAfterSave)), "
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
            if let mgr = tempManager {
                await cleanupManagers([mgr], profileStore: profileStore, store: store)
            } else {
                await store.backend.setConfigurationChangeObservationPaused(false)
                await store.reloadFromBackend()
            }
            return failedOutcome(
                id: .quirk1ActiveTunnelSave,
                summary: error.localizedDescription,
                detail: String(describing: error),
                start: start,
                clock: clock
            )
        }
    }

    static func cleanupOnDemandTempManager(
        _ manager: NETunnelProviderManager?,
        profileStore: ProfileStore,
        store: TunnelStore
    ) async {
        if let mgr = manager {
            mgr.isOnDemandEnabled = false
            try? await mgr.saveToPreferences()
            await cleanupManagers([mgr], profileStore: profileStore, store: store)
        } else {
            await store.backend.setConfigurationChangeObservationPaused(false)
            await store.reloadFromBackend()
        }
    }

    static func makeQuirkOutcome(
        checkID: AutomatedCheckID,
        finding: IOSQuirkFinding,
        summary: String,
        elapsedMs: Int
    ) -> NetworkCheckOutcome {
        NetworkCheckOutcome(
            result: AutomatedCheckResult(
                id: checkID,
                status: .passed,
                summary: summary,
                detail: finding.observation,
                durationMilliseconds: elapsedMs
            ),
            updatedQuirks: [finding]
        )
    }

    static func activeTunnelSkipOutcome(
        checkID: AutomatedCheckID,
        activeName: String,
        reason: String,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> NetworkCheckOutcome {
        let msg = "Skipped because '\(activeName)' is active. Disconnect it to \(reason)."
        return NetworkCheckOutcome(
            result: AutomatedCheckResult(
                id: checkID,
                status: .info,
                summary: "Skipped while '\(activeName)' is active",
                detail: msg,
                durationMilliseconds: durationMs(since: start, clock: clock)
            )
        )
    }

    static func quirk1InfoOutcome(
        summary: String,
        detail: String,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> NetworkCheckOutcome {
        NetworkCheckOutcome(
            result: AutomatedCheckResult(
                id: .quirk1ActiveTunnelSave,
                status: .info,
                summary: summary,
                detail: detail,
                durationMilliseconds: durationMs(since: start, clock: clock)
            ),
            updatedQuirks: [
                IOSQuirkFinding(id: .saveNewDeactivatesActive, status: .needsActiveTunnel, observation: detail)
            ]
        )
    }
}
#endif
