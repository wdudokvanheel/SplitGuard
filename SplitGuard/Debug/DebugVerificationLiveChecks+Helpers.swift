#if DEBUG && !targetEnvironment(simulator)
import Foundation
import NetworkExtension
import SplitGuardCore
import WireGuardEngine

struct LiveCheckError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct LiveMetricsSnapshot {
    let endpoint: String
    let rxBytes: UInt64
    let txBytes: UInt64
    let hasHandshake: Bool

    var descriptionText: String {
        "Endpoint=\(endpoint), RX=\(rxBytes) B, TX=\(txBytes) B, handshake=\(hasHandshake)"
    }
}

struct SplitDNSLiveProbeReport {
    let passed: Bool
    let detail: String
}

struct KillSwitchCycleReport {
    let allPassed: Bool
    let detail: String
}

struct LiveEditMTUResult {
    let sawRestart: Bool
    let reconnected: Bool
    let updatedMTU: UInt16?
}

extension DebugVerificationLiveChecks {
    static func shortSuffix() -> String {
        String(UUID().uuidString.prefix(5))
    }

    static func createSwitchPair(
        serverFixture: DebugBundledFixture,
        certFixture: DebugBundledFixture,
        store: TunnelStore
    ) async throws -> (Tunnel, Tunnel) {
        let suffix = shortSuffix()
        let prefix = DebugVerificationNetworkChecks.probeNamePrefix
        let profileA = try DebugBundledFixtures.parsedProfile(for: serverFixture, named: "\(prefix)SWA_\(suffix)")
        let profileB = try DebugBundledFixtures.parsedProfile(for: certFixture, named: "\(prefix)SWB_\(suffix)")
        let tunnelA = try await store.addTunnel(profileA)
        let tunnelB = try await store.addTunnel(profileB)
        return (tunnelA, tunnelB)
    }

    static func verifySwitchFrom(_ tunnelA: Tunnel, to tunnelB: Tunnel, store: TunnelStore) async throws {
        try await activateAndWaitActive(tunnel: tunnelA, store: store)
        await store.setTunnelActive(true, for: tunnelB)
        let aStopped = await waitUntil(timeout: .seconds(12)) { await MainActor.run { tunnelA.status == .inactive } }
        let bActive = await waitUntil(timeout: .seconds(15)) { await MainActor.run { tunnelB.status == .active } }
        guard aStopped && bActive else {
            throw LiveCheckError("Switch failed: tunnelA.inactive=\(aStopped), tunnelB.active=\(bActive)")
        }
    }

    static func verifyLiveEditMTU(_ tunnel: Tunnel, store: TunnelStore) async throws -> LiveEditMTUResult {
        var editedProfile = await MainActor.run { tunnel.profile }
        editedProfile.interface.mtu = 1380
        _ = try await store.updateTunnel(tunnel, profile: editedProfile, onDemandPolicy: .off)
        let sawRestart = await waitUntil(timeout: .seconds(6)) {
            await MainActor.run { tunnel.status == .restarting || tunnel.status == .inactive || tunnel.status == .activating }
        }
        let reconnected = await waitUntil(timeout: .seconds(15)) { await MainActor.run { tunnel.status == .active } }
        let updatedMTU = await MainActor.run { tunnel.profile.interface.mtu }
        return LiveEditMTUResult(sawRestart: sawRestart, reconnected: reconnected, updatedMTU: updatedMTU)
    }

    static func executeSplitDNSLookups(
        splitDomain: String,
        tunnel: Tunnel,
        store: TunnelStore
    ) async -> SplitDNSLiveProbeReport {
        let publicLookup = await DNSLookupService.resolve(hostname: "example.com")
        let excludedLookup = await DNSLookupService.resolve(hostname: splitDomain)
        let internalHost = "netserver.\(splitDomain)"
        let internalLookup = await DNSLookupService.resolve(hostname: internalHost)
        let physReply = await store.backend.sendProviderMessage(.debugPhysicalDNSProbe(name: splitDomain), to: tunnel.id)

        let pubText = formatLookup(publicLookup)
        let exclText = formatLookup(excludedLookup)
        let intText = formatLookup(internalLookup)
        let detail = [
            "Split domain: \(splitDomain) (exact apex excluded).",
            "Public lookup (example.com): \(pubText)",
            "Excluded apex (\(splitDomain)): \(exclText)",
            "Matched host (\(internalHost)): \(intText)",
            "Physical DNS IPC probe: \(describePhysicalProbe(physReply))"
        ].joined(separator: "\n")

        let probe: PhysicalDNSProbeResult?
        if case .debugPhysicalDNSProbe(let result) = physReply { probe = result } else { probe = nil }
        return SplitDNSLiveProbeReport(
            passed: splitDNSPassed(publicOK: publicLookup.succeeded,
                                   apex: excludedLookup.succeeded ? excludedLookup.addresses : [],
                                   internalAnswers: internalLookup.succeeded ? internalLookup.addresses : [],
                                   probe: probe),
            detail: detail
        )
    }

    static func executeKillSwitchCycle(
        tunnel: Tunnel,
        profile: inout TunnelProfile,
        name: String,
        store: TunnelStore
    ) async throws -> KillSwitchCycleReport {
        try await activateAndWaitActive(tunnel: tunnel, store: store)
        let firstMetrics = await driveTrafficAndAwaitMetrics(tunnel: tunnel, store: store)
        let strictFlags = await readProtocolKillSwitchFlags(named: name)
        try await stopAndWaitInactive(tunnel: tunnel, store: store)

        let session = try await startCacheProbe(named: name, tunnel: tunnel)
        let cachedMetrics = await driveTrafficAndAwaitMetrics(tunnel: tunnel, store: store)

        let selected: String? = await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(DebugCacheProbeMessage.request) { response in
                    continuation.resume(returning: response.flatMap { String(data: $0, encoding: .utf8) })
                }
            } catch { continuation.resume(returning: nil) }
        }

        profile.options = TunnelOptions(killSwitch: .init(isEnabled: true, allowLocalNetwork: true))
        _ = try await store.updateTunnel(tunnel, profile: profile, onDemandPolicy: .off)
        let lanReconnected = await waitUntil(timeout: .seconds(15)) { await MainActor.run { tunnel.status == .active } }
        let lanFlags = await readProtocolKillSwitchFlags(named: name)

        let detail = [
            "Strict KS flags: includeAll=\(strictFlags.includeAll), excludeLAN=\(strictFlags.excludeLAN)",
            "First connect metrics: \(firstMetrics?.descriptionText ?? "none")",
            "Cached address selected with fixture DNS unavailable: \(selected ?? "none")",
            "Endpoint-cache reconnect metrics: \(cachedMetrics?.descriptionText ?? "none")",
            "Allow-LAN flags: includeAll=\(lanFlags.includeAll), excludeLAN=\(lanFlags.excludeLAN), reconnected=\(lanReconnected)"
        ].joined(separator: "\n")

        let allPassed = strictFlags.includeAll && !strictFlags.excludeLAN
            && lanFlags.includeAll && lanFlags.excludeLAN
            && cacheReconnectPassed(handshake: cachedMetrics?.hasHandshake == true, forcedLookupFailure: selected != nil)
            && lanReconnected
        return KillSwitchCycleReport(allPassed: allPassed, detail: detail)
    }

    static func startCacheProbe(named name: String, tunnel: Tunnel) async throws -> NETunnelProviderSession {
        guard name.hasPrefix(DebugVerificationNetworkChecks.probeNamePrefix + "KS_"),
              let manager = try await NETunnelProviderManager.loadAllFromPreferences().first(where: { $0.localizedDescription == name }),
              let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol,
              configuration.providerBundleIdentifier == Bundle.main.bundleIdentifier.map({ $0 + ".network-extension" }),
              let reference = configuration.passwordReference,
              let session = manager.connection as? NETunnelProviderSession else {
            throw LiveCheckError("Disposable cache probe manager unavailable")
        }
        try session.startTunnel(options: [DebugCacheProbeMessage.startOption: reference as NSData, "startedByApp": NSNumber(value: true)])
        guard await waitUntil(timeout: .seconds(15), condition: { await MainActor.run { tunnel.status == .active } }) else {
            throw LiveCheckError("Cache probe reconnect failed with fixture DNS unavailable")
        }
        return session
    }

    static func skipIfBlocked(
        id: AutomatedCheckID,
        requireBoth: Bool,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> NetworkCheckOutcome? {
        if let activeName = await DebugVerificationNetworkChecks.activeNonProbeTunnelName() {
            let msg = "Skipped while user tunnel '\(activeName)' is active. Disconnect it and re-run."
            return NetworkCheckOutcome(
                result: AutomatedCheckResult(
                    id: id, status: .info,
                    summary: "Skipped while '\(activeName)' is active",
                    detail: msg,
                    durationMilliseconds: DebugVerificationNetworkChecks.durationMs(since: start, clock: clock)
                )
            )
        }
        let availableCount = DebugBundledFixtures.allAvailable().count
        if (requireBoth && availableCount < 2) || availableCount == 0 {
            return missingFixtureOutcome(id: id, start: start, clock: clock)
        }
        return nil
    }

    static func missingFixtureOutcome(
        id: AutomatedCheckID,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> NetworkCheckOutcome {
        NetworkCheckOutcome(
            result: AutomatedCheckResult(
                id: id, status: .info,
                summary: "Bundled docs/*.conf fixtures missing from app bundle",
                detail: "Rebuild Debug with docs/ServerTest.conf and docs/TestCert.conf present.",
                durationMilliseconds: DebugVerificationNetworkChecks.durationMs(since: start, clock: clock)
            )
        )
    }

    static func activateAndWaitActive(tunnel: Tunnel, store: TunnelStore) async throws {
        await store.setTunnelActive(true, for: tunnel)
        let active = await waitUntil(timeout: .seconds(15)) { await MainActor.run { tunnel.status == .active } }
        guard active else {
            let name = await MainActor.run { tunnel.name }
            let errText = await MainActor.run { store.lastActivationError?.message ?? "status=\(tunnel.status)" }
            throw LiveCheckError("Tunnel '\(name)' did not reach Active: \(errText)")
        }
    }

    static func stopAndWaitInactive(tunnel: Tunnel, store: TunnelStore) async throws {
        await store.setTunnelActive(false, for: tunnel)
        let inactive = await waitUntil(timeout: .seconds(10)) { await MainActor.run { tunnel.status == .inactive } }
        guard inactive else {
            throw LiveCheckError("Tunnel did not return to Inactive within 10s.")
        }
    }

    static func driveTrafficAndAwaitMetrics(tunnel: Tunnel, store: TunnelStore) async -> LiveMetricsSnapshot? {
        Task.detached {
            _ = await DNSLookupService.resolve(hostname: "example.com")
            if let url = URL(string: "https://1.1.1.1") {
                var request = URLRequest(url: url)
                request.timeoutInterval = 3
                _ = try? await URLSession.shared.data(for: request)
            }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        var latest: LiveMetricsSnapshot?
        while ContinuousClock.now < deadline {
            if let status = await store.fetchDeviceStatus(for: tunnel) {
                let rxTotal = status.peers.reduce(UInt64(0)) { $0 &+ $1.rxBytes }
                let txTotal = status.peers.reduce(UInt64(0)) { $0 &+ $1.txBytes }
                let endpoint = status.peers.first?.endpoint?.description ?? "none"
                let hasHandshake = status.peers.contains { $0.lastHandshake != nil }
                let snap = LiveMetricsSnapshot(
                    endpoint: endpoint, rxBytes: rxTotal, txBytes: txTotal, hasHandshake: hasHandshake
                )
                latest = snap
                if hasHandshake && rxTotal > 0 && txTotal > 0 { return snap }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return latest
    }

    static func readProtocolKillSwitchFlags(named name: String) async -> (includeAll: Bool, excludeLAN: Bool) {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        guard let mgr = managers.first(where: { $0.localizedDescription == name }),
              let proto = mgr.protocolConfiguration as? NETunnelProviderProtocol else {
            return (false, false)
        }
        return (proto.includeAllNetworks, proto.excludeLocalNetworks)
    }

    static func formatLookup(_ result: DNSLookupResult) -> String {
        result.succeeded
            ? "\(result.addresses.joined(separator: ", ")) (\(result.durationMilliseconds) ms)"
            : (result.errorMessage ?? "failed")
    }

    static func describePhysicalProbe(_ reply: ProviderReply?) -> String {
        guard case .debugPhysicalDNSProbe(let probe) = reply else { return "No reply" }
        if let err = probe.error { return "error=\(err)" }
        let ifIndex = probe.interfaceIndex.map(String.init) ?? "nil"
        let rcode = probe.responseCode.map(String.init) ?? "nil"
        let recs = probe.records.joined(separator: ", ")
        return "ifIndex=\(ifIndex), rcode=\(rcode), records=[\(recs)]"
    }

    static func cleanupTempTunnels(_ tunnels: [Tunnel], in store: TunnelStore) async {
        for tunnel in tunnels {
            if await MainActor.run(body: { tunnel.status != .inactive }) {
                await store.setTunnelActive(false, for: tunnel)
                _ = await waitUntil(timeout: .seconds(5)) { await MainActor.run { tunnel.status == .inactive } }
            }
            _ = await store.delete(tunnel: tunnel)
        }
    }

    static func waitUntil(timeout: Duration, condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return await condition()
    }

    static func passLive(
        id: AutomatedCheckID, summary: String, detail: String,
        start: ContinuousClock.Instant, clock: ContinuousClock
    ) -> NetworkCheckOutcome {
        NetworkCheckOutcome(
            result: AutomatedCheckResult(
                id: id, status: .passed, summary: summary, detail: detail,
                durationMilliseconds: DebugVerificationNetworkChecks.durationMs(since: start, clock: clock)
            )
        )
    }

    static func failLive(
        id: AutomatedCheckID, summary: String, detail: String,
        start: ContinuousClock.Instant, clock: ContinuousClock
    ) -> NetworkCheckOutcome {
        NetworkCheckOutcome(
            result: AutomatedCheckResult(
                id: id, status: .failed, summary: summary, detail: detail,
                durationMilliseconds: DebugVerificationNetworkChecks.durationMs(since: start, clock: clock)
            )
        )
    }
}
#endif
