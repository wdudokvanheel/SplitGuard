import Foundation
import Observation
import WireGuardKit

@MainActor
@Observable
final class TunnelLiveMetricsMonitor {
    private(set) var totalRxBytes: UInt64 = 0
    private(set) var totalTxBytes: UInt64 = 0
    private(set) var latestHandshakeDate: Date?
    private(set) var hasLiveStats = false
    private(set) var now = Date()

    private var monitoredTunnelID: ObjectIdentifier?
    private weak var monitoredTunnel: TunnelContainer?
    private var pollingTask: Task<Void, Never>?

    var rxFormatted: String {
        TunnelDetailViewModel.formatBytes(totalRxBytes)
    }

    var txFormatted: String {
        TunnelDetailViewModel.formatBytes(totalTxBytes)
    }

    var handshakeAgeText: String? {
        Self.formatHandshakeAge(from: latestHandshakeDate, now: now)
    }

    func update(tunnel: TunnelContainer?, status: TunnelStatus, isVisible: Bool) {
        guard isVisible, let tunnel, status == .active else {
            stop()
            if tunnel.map(ObjectIdentifier.init) != monitoredTunnelID || status == .inactive {
                resetMetrics()
                monitoredTunnel = tunnel
                monitoredTunnelID = tunnel.map(ObjectIdentifier.init)
            }
            return
        }

        let targetID = ObjectIdentifier(tunnel)
        if monitoredTunnelID != targetID {
            stop()
            resetMetrics()
            monitoredTunnel = tunnel
            monitoredTunnelID = targetID
        }
        startPollingIfNeeded()
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func resetMetrics() {
        totalRxBytes = 0
        totalTxBytes = 0
        latestHandshakeDate = nil
        hasLiveStats = false
    }

    private func startPollingIfNeeded() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func pollOnce() async {
        guard let tunnel = monitoredTunnel else { return }
        let runtimeConfig: TunnelConfiguration? = await withCheckedContinuation { continuation in
            tunnel.getRuntimeTunnelConfiguration { config in
                continuation.resume(returning: config)
            }
        }
        guard !Task.isCancelled else { return }
        now = Date()
        guard let runtimeConfig else { return }
        apply(configuration: runtimeConfig)
    }

    func apply(configuration: TunnelConfiguration) {
        let peers = configuration.peers
        totalRxBytes = peers.compactMap(\.rxBytes).reduce(0, +)
        totalTxBytes = peers.compactMap(\.txBytes).reduce(0, +)
        latestHandshakeDate = peers.compactMap(\.lastHandshakeTime).max()
        hasLiveStats = peers.contains {
            $0.rxBytes != nil || $0.txBytes != nil || $0.lastHandshakeTime != nil
        }
    }

    static func formatHandshakeAge(from date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let elapsed = Int(max(0, now.timeIntervalSince(date)))
        switch elapsed {
        case 0 ..< 5:
            return "Just now"
        case 5 ..< 60:
            return "\(elapsed)s ago"
        case 60 ..< 3600:
            let minutes = elapsed / 60
            let seconds = elapsed % 60
            return seconds == 0 ? "\(minutes)m ago" : "\(minutes)m \(seconds)s"
        case 3600 ..< 86400:
            let hours = elapsed / 3600
            let minutes = (elapsed % 3600) / 60
            return minutes == 0 ? "\(hours)h ago" : "\(hours)h \(minutes)m"
        default:
            let days = elapsed / 86400
            return "\(days)d ago"
        }
    }
}
