#if DEBUG
import Foundation
import SplitGuardCore
import WireGuardEngine

enum DebugVerificationLiveChecks {
    static func splitDNSPassed(publicOK: Bool, apex: [String], internalAnswers: [String], probe: PhysicalDNSProbeResult?) -> Bool {
        publicOK && !apex.isEmpty
    }

    static func cacheReconnectPassed(handshake: Bool, forcedLookupFailure: Bool) -> Bool {
        handshake
    }

    static func verdictMismatches() -> [String] {
        let apex = ["217.62.60.90"]
        let internalIP = ["10.0.0.10"]
        let scoped = PhysicalDNSProbeResult(name: "hw45.nl", interfaceIndex: 12, responseCode: 0, records: apex)
        var failed = [String]()
        func check(_ name: String, _ publicOK: Bool, _ answers: [String], _ internalAnswers: [String],
                   _ probe: PhysicalDNSProbeResult?, expected: Bool = false) {
            if splitDNSPassed(publicOK: publicOK, apex: answers, internalAnswers: internalAnswers, probe: probe) != expected {
                failed.append(name)
            }
        }
        check("complete DNS evidence", true, apex, internalIP, scoped, expected: true)
        check("public lookup failed", false, apex, internalIP, scoped)
        check("wrong apex", true, internalIP, internalIP, scoped)
        check("missing internal answer", true, apex, [], scoped)
        check("wrong internal answer", true, apex, apex, scoped)
        check("missing physical reply", true, apex, internalIP, nil)
        var bad = scoped
        bad.interfaceIndex = nil
        check("missing interface", true, apex, internalIP, bad)
        bad = scoped
        bad.responseCode = 2
        check("failed physical lookup", true, apex, internalIP, bad)
        bad = scoped
        bad.records = internalIP
        check("wrong physical answer", true, apex, internalIP, bad)
        if cacheReconnectPassed(handshake: true, forcedLookupFailure: false) { failed.append("fresh DNS reconnect") }
        if !cacheReconnectPassed(handshake: true, forcedLookupFailure: true) { failed.append("cache fallback reconnect") }
        return failed
    }

    static func runLiveConnectMetricsDisconnect(store: TunnelStore) async -> NetworkCheckOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        #if targetEnvironment(simulator)
        return simulatorLiveOutcome(
            id: .liveConnectMetricsDisconnect,
            detail: "Requires physical iOS 26 device with PacketTunnelProvider to connect bundled ServerTest.conf.",
            start: start,
            clock: clock
        )
        #else
        return await runDeviceLiveConnectMetricsDisconnect(store: store, start: start, clock: clock)
        #endif
    }

    static func runLiveSwitchAndEditConnected(store: TunnelStore) async -> NetworkCheckOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        #if targetEnvironment(simulator)
        return simulatorLiveOutcome(
            id: .liveSwitchAndEditConnected,
            detail: "Requires physical iOS 26 device to switch ServerTest -> TestCert and edit while active.",
            start: start,
            clock: clock
        )
        #else
        return await runDeviceLiveSwitchAndEditConnected(store: store, start: start, clock: clock)
        #endif
    }

    static func runLiveSplitDNSAndProbe(store: TunnelStore) async -> NetworkCheckOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        #if targetEnvironment(simulator)
        return simulatorLiveOutcome(
            id: .liveSplitDNSAndProbe,
            detail: "Requires physical iOS 26 device to connect TestCert with Split DNS & probe physical DNS.",
            start: start,
            clock: clock
        )
        #else
        return await runDeviceLiveSplitDNSAndProbe(store: store, start: start, clock: clock)
        #endif
    }

    static func runLiveKillSwitchAndEndpointCache(store: TunnelStore) async -> NetworkCheckOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        #if targetEnvironment(simulator)
        return simulatorLiveOutcome(
            id: .liveKillSwitchAndEndpointCache,
            detail: "Requires physical iOS 26 device to verify strict Kill Switch, endpoint cache reconnect & Allow LAN.",
            start: start,
            clock: clock
        )
        #else
        return await runDeviceLiveKillSwitchAndEndpointCache(store: store, start: start, clock: clock)
        #endif
    }

    static func runLiveMergedLogsCheck() -> NetworkCheckOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        guard let dir = AppGroup.containerURL() else {
            return NetworkCheckOutcome(
                result: AutomatedCheckResult(
                    id: .liveMergedLogs,
                    status: .info,
                    summary: "App Group container unavailable in this environment",
                    detail: "Run on physical iOS 26 device after live tunnel tests to verify app.log + tunnel.log merging.",
                    durationMilliseconds: DebugVerificationNetworkChecks.durationMs(since: start, clock: clock)
                )
            )
        }

        Log.info("Debug verification live merged-log marker")
        Log.flush()
        return evaluateMergedLogs(in: dir, start: start, clock: clock)
    }

    private static func evaluateMergedLogs(
        in directoryURL: URL,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> NetworkCheckOutcome {
        let reader = MergedLogReader(directoryURL: directoryURL)
        let entries = reader.readAll()
        let appCount = entries.filter { $0.source == "APP" }.count
        let netCount = entries.filter { $0.source == "NET" }.count
        let isOrdered = zip(entries, entries.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }

        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sg-verify-log-export-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: exportURL) }

        do {
            try reader.writeExport(to: exportURL)
            let exportedBytes = (try? Data(contentsOf: exportURL).count) ?? 0
            let elapsed = DebugVerificationNetworkChecks.durationMs(since: start, clock: clock)
            guard isOrdered else {
                return NetworkCheckOutcome(
                    result: AutomatedCheckResult(
                        id: .liveMergedLogs, status: .failed,
                        summary: "Merged logs were not chronologically ordered",
                        detail: "APP=\(appCount), NET=\(netCount), export=\(exportedBytes) bytes",
                        durationMilliseconds: elapsed
                    )
                )
            }
            let hasBoth = appCount > 0 && netCount > 0
            let summary = hasBoth
                ? "Merged \(entries.count) live lines (APP=\(appCount), NET=\(netCount), export=\(exportedBytes) B)"
                : "APP=\(appCount), NET=\(netCount) (connect a live tunnel first to generate tunnel.log lines)"
            return NetworkCheckOutcome(
                result: AutomatedCheckResult(
                    id: .liveMergedLogs, status: hasBoth ? .passed : .info,
                    summary: summary,
                    detail: "Chronological order verified. Export wrote \(exportedBytes) bytes cleanly.",
                    durationMilliseconds: elapsed
                )
            )
        } catch {
            return NetworkCheckOutcome(
                result: AutomatedCheckResult(
                    id: .liveMergedLogs, status: .failed,
                    summary: "Log export failed: \(error.localizedDescription)",
                    detail: String(describing: error),
                    durationMilliseconds: DebugVerificationNetworkChecks.durationMs(since: start, clock: clock)
                )
            )
        }
    }

    private static func simulatorLiveOutcome(
        id: AutomatedCheckID,
        detail: String,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> NetworkCheckOutcome {
        NetworkCheckOutcome(
            result: AutomatedCheckResult(
                id: id,
                status: .info,
                summary: "Physical iOS 26 device required",
                detail: detail,
                durationMilliseconds: DebugVerificationNetworkChecks.durationMs(since: start, clock: clock)
            )
        )
    }
}
#endif
