#if DEBUG && !targetEnvironment(simulator)
import Foundation
import NetworkExtension
import SplitGuardCore
import WireGuardEngine

extension DebugVerificationLiveChecks {
    static func runDeviceLiveConnectMetricsDisconnect(
        store: TunnelStore,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome {
        if let skip = await skipIfBlocked(id: .liveConnectMetricsDisconnect, requireBoth: false, start: start, clock: clock) {
            return skip
        }
        guard let fixture = DebugBundledFixtures.serverTest() else {
            return missingFixtureOutcome(id: .liveConnectMetricsDisconnect, start: start, clock: clock)
        }

        var tempTunnel: Tunnel?
        do {
            let name = "\(DebugVerificationNetworkChecks.probeNamePrefix)LIVE_\(shortSuffix())"
            let profile = try DebugBundledFixtures.parsedProfile(for: fixture, named: name)
            let tunnel = try await store.addTunnel(profile, onDemandPolicy: .off)
            tempTunnel = tunnel

            try await activateAndWaitActive(tunnel: tunnel, store: store)
            let metrics = await driveTrafficAndAwaitMetrics(tunnel: tunnel, store: store)
            try await stopAndWaitInactive(tunnel: tunnel, store: store)
            await cleanupTempTunnels([tunnel], in: store)

            guard let metrics, metrics.hasHandshake, metrics.rxBytes > 0, metrics.txBytes > 0 else {
                return failLive(
                    id: .liveConnectMetricsDisconnect,
                    summary: "Connected but did not observe handshake + RX/TX counters",
                    detail: metrics?.descriptionText ?? "ProviderMessage.status returned nil",
                    start: start,
                    clock: clock
                )
            }
            return passLive(
                id: .liveConnectMetricsDisconnect,
                summary: "Handshake + RX \(metrics.rxBytes) B / TX \(metrics.txBytes) B + clean stop",
                detail: metrics.descriptionText,
                start: start,
                clock: clock
            )
        } catch {
            await cleanupTempTunnels([tempTunnel].compactMap { $0 }, in: store)
            return failLive(
                id: .liveConnectMetricsDisconnect, summary: error.localizedDescription,
                detail: String(describing: error), start: start, clock: clock
            )
        }
    }

    static func runDeviceLiveSwitchAndEditConnected(
        store: TunnelStore,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome {
        if let skip = await skipIfBlocked(id: .liveSwitchAndEditConnected, requireBoth: true, start: start, clock: clock) {
            return skip
        }
        guard let serverFixture = DebugBundledFixtures.serverTest(),
              let certFixture = DebugBundledFixtures.testCert() else {
            return missingFixtureOutcome(id: .liveSwitchAndEditConnected, start: start, clock: clock)
        }

        var tempTunnels: [Tunnel] = []
        do {
            let (tunnelA, tunnelB) = try await createSwitchPair(
                serverFixture: serverFixture,
                certFixture: certFixture,
                store: store
            )
            tempTunnels = [tunnelA, tunnelB]

            try await verifySwitchFrom(tunnelA, to: tunnelB, store: store)
            let editResult = try await verifyLiveEditMTU(tunnelB, store: store)
            try await stopAndWaitInactive(tunnel: tunnelB, store: store)
            await cleanupTempTunnels(tempTunnels, in: store)

            guard editResult.reconnected && editResult.updatedMTU == 1380 else {
                let mtuText = String(describing: editResult.updatedMTU)
                return failLive(
                    id: .liveSwitchAndEditConnected,
                    summary: "Edit while connected did not reconnect cleanly",
                    detail: "sawRestart=\(editResult.sawRestart), reconnected=\(editResult.reconnected), mtu=\(mtuText)",
                    start: start,
                    clock: clock
                )
            }
            let detail = [
                "Switch ServerTest -> TestCert cleanly stopped A and activated B.",
                "Edit while active (MTU 1420 -> 1380) triggered reconnect (sawRestart=\(editResult.sawRestart))."
            ].joined(separator: "\n")
            return passLive(
                id: .liveSwitchAndEditConnected,
                summary: "Switch A -> B & live edit reconnect passed",
                detail: detail,
                start: start,
                clock: clock
            )
        } catch {
            await cleanupTempTunnels(tempTunnels, in: store)
            return failLive(
                id: .liveSwitchAndEditConnected, summary: error.localizedDescription,
                detail: String(describing: error), start: start, clock: clock
            )
        }
    }

    static func runDeviceLiveSplitDNSAndProbe(
        store: TunnelStore,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome {
        if let skip = await skipIfBlocked(id: .liveSplitDNSAndProbe, requireBoth: false, start: start, clock: clock) {
            return skip
        }
        guard let fixture = DebugBundledFixtures.testCert() else {
            return missingFixtureOutcome(id: .liveSplitDNSAndProbe, start: start, clock: clock)
        }

        var tempTunnel: Tunnel?
        do {
            let name = "\(DebugVerificationNetworkChecks.probeNamePrefix)SDNS_\(shortSuffix())"
            var profile = try DebugBundledFixtures.parsedProfile(for: fixture, named: name)
            let splitDomain = profile.peers.first?.endpoint?.hostname ?? "internal.example"
            profile.splitDNS = SplitDNSConfiguration(
                mode: .onlyDomains,
                domains: [.init(name: splitDomain)],
                exclusions: [.init(name: splitDomain, includesSubdomains: false)]
            )

            let tunnel = try await store.addTunnel(profile, onDemandPolicy: .off)
            tempTunnel = tunnel
            try await activateAndWaitActive(tunnel: tunnel, store: store)

            let probeReport = await executeSplitDNSLookups(splitDomain: splitDomain, tunnel: tunnel, store: store)
            try await stopAndWaitInactive(tunnel: tunnel, store: store)
            await cleanupTempTunnels([tunnel], in: store)

            guard probeReport.publicOK && probeReport.excludedOK else {
                return failLive(
                    id: .liveSplitDNSAndProbe,
                    summary: "Split DNS public or excluded-apex lookup failed",
                    detail: probeReport.detail,
                    start: start,
                    clock: clock
                )
            }
            let summary = "Split DNS active; public, apex & internal (\(probeReport.internalOK ? "OK" : "N/A")) checked"
            return passLive(id: .liveSplitDNSAndProbe, summary: summary, detail: probeReport.detail, start: start, clock: clock)
        } catch {
            await cleanupTempTunnels([tempTunnel].compactMap { $0 }, in: store)
            return failLive(
                id: .liveSplitDNSAndProbe, summary: error.localizedDescription,
                detail: String(describing: error), start: start, clock: clock
            )
        }
    }

    static func runDeviceLiveKillSwitchAndEndpointCache(
        store: TunnelStore,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome {
        if let skip = await skipIfBlocked(id: .liveKillSwitchAndEndpointCache, requireBoth: false, start: start, clock: clock) {
            return skip
        }
        guard let fixture = DebugBundledFixtures.serverTest() else {
            return missingFixtureOutcome(id: .liveKillSwitchAndEndpointCache, start: start, clock: clock)
        }

        var tempTunnel: Tunnel?
        do {
            let name = "\(DebugVerificationNetworkChecks.probeNamePrefix)KS_\(shortSuffix())"
            var profile = try DebugBundledFixtures.parsedProfile(for: fixture, named: name)
            profile.options = TunnelOptions(killSwitch: .init(isEnabled: true, allowLocalNetwork: false))
            let tunnel = try await store.addTunnel(profile, onDemandPolicy: .off)
            tempTunnel = tunnel

            let report = try await executeKillSwitchCycle(tunnel: tunnel, profile: &profile, name: name, store: store)
            try await stopAndWaitInactive(tunnel: tunnel, store: store)
            await cleanupTempTunnels([tunnel], in: store)

            guard report.allPassed else {
                return failLive(
                    id: .liveKillSwitchAndEndpointCache,
                    summary: "Kill Switch flags or endpoint-cache reconnect check failed",
                    detail: report.detail,
                    start: start,
                    clock: clock
                )
            }
            return passLive(
                id: .liveKillSwitchAndEndpointCache,
                summary: "Strict KS, endpoint-cache reconnect & Allow-LAN update all passed",
                detail: report.detail,
                start: start,
                clock: clock
            )
        } catch {
            await cleanupTempTunnels([tempTunnel].compactMap { $0 }, in: store)
            return failLive(
                id: .liveKillSwitchAndEndpointCache, summary: error.localizedDescription,
                detail: String(describing: error), start: start, clock: clock
            )
        }
    }
}
#endif
