// SPDX-License-Identifier: MIT

import Foundation
import Observation
import SplitGuardCore
import WireGuardEngine

@MainActor
@Observable
final class TunnelLiveMetricsMonitor {
    private(set) var totalRxBytes: UInt64 = 0
    private(set) var totalTxBytes: UInt64 = 0
    private(set) var latestHandshakeDate: Date?
    private(set) var hasLiveStats = false
    private(set) var now = Date()
    private(set) var deviceStatus: DeviceStatus?
    private(set) var monitoredTunnelID: Tunnel.ID?

    private weak var monitoredTunnel: Tunnel?
    private weak var store: TunnelStore?
    private var pollingTask: Task<Void, Never>?

    var healthState: TunnelHealthState? {
        TunnelHealthState.evaluate(
            killSwitchEnabled: monitoredTunnel?.options.killSwitch.isEnabled ?? false,
            deviceStatus: deviceStatus
        )
    }

    func healthState(for tunnel: Tunnel) -> TunnelHealthState? {
        guard tunnel.id == monitoredTunnelID else { return nil }
        return healthState
    }

    var killSwitchBlockState: KillSwitchBlockState? {
        if case .blocking(let state) = healthState {
            return state
        }
        return nil
    }

    func killSwitchBlockState(for tunnel: Tunnel) -> KillSwitchBlockState? {
        guard tunnel.id == monitoredTunnelID else { return nil }
        return killSwitchBlockState
    }

    var rxFormatted: String {
        Self.formatBytes(totalRxBytes)
    }

    var txFormatted: String {
        Self.formatBytes(totalTxBytes)
    }

    var handshakeAgeText: String? {
        Self.formatHandshakeAge(from: latestHandshakeDate, now: now)
    }

    func handshakeSummaryText(for tunnel: Tunnel) -> String {
        if tunnel.id == monitoredTunnelID, let ageText = handshakeAgeText {
            return ageText
        }
        switch healthState(for: tunnel) {
        case .noHandshake(let attempts) where attempts > 0:
            return L10n.tr("tunnel.handshake.attempts", defaultValue: "\(attempts) attempts")
        case .noHandshake:
            return L10n.tr("tunnel.handshake.none", defaultValue: "None")
        case .idle:
            return L10n.tr("tunnel.metric.idle", defaultValue: "Idle")
        case .connecting, .stalled, .blocking, .healthy, .none:
            return L10n.tr("tunnel.handshake.pending", defaultValue: "Pending")
        }
    }

    func update(tunnel: Tunnel?, status: TunnelStatus, store: TunnelStore, isVisible: Bool) {
        self.store = store
        guard isVisible, let tunnel, status == .active else {
            stop()
            if tunnel?.id != monitoredTunnelID || status == .inactive {
                resetMetrics()
                monitoredTunnel = tunnel
                monitoredTunnelID = tunnel?.id
            }
            return
        }

        if monitoredTunnelID != tunnel.id {
            stop()
            resetMetrics()
            monitoredTunnel = tunnel
            monitoredTunnelID = tunnel.id
        }
        startPollingIfNeeded()
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func apply(deviceStatus: DeviceStatus?) {
        self.deviceStatus = deviceStatus
        guard let deviceStatus else {
            totalRxBytes = 0
            totalTxBytes = 0
            latestHandshakeDate = nil
            hasLiveStats = false
            return
        }

        let peers = deviceStatus.peers
        totalRxBytes = peers.reduce(0) { $0 &+ $1.rxBytes }
        totalTxBytes = peers.reduce(0) { $0 &+ $1.txBytes }
        latestHandshakeDate = peers.compactMap(\.lastHandshake).max()
        hasLiveStats = peers.contains {
            $0.rxBytes > 0 || $0.txBytes > 0 || $0.lastHandshake != nil
        }
    }

    private func resetMetrics() {
        totalRxBytes = 0
        totalTxBytes = 0
        latestHandshakeDate = nil
        hasLiveStats = false
        deviceStatus = nil
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
        guard let tunnel = monitoredTunnel, let store else { return }
        let fetchedStatus = await store.fetchDeviceStatus(for: tunnel)
        guard !Task.isCancelled else { return }
        now = Date()
        apply(deviceStatus: fetchedStatus)
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .binary).locale(AppLocalization.currentLocale))
    }

    static func formatHandshakeAge(from date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let elapsed = Int(max(0, now.timeIntervalSince(date)))
        switch elapsed {
        case 0 ..< 5:
            return L10n.tr("tunnel.handshake.justNow", defaultValue: "Just now")
        case 5 ..< 60:
            return L10n.tr("tunnel.handshake.secondsAgo", defaultValue: "\(elapsed)s ago")
        case 60 ..< 3600:
            let minutes = elapsed / 60
            let seconds = elapsed % 60
            return seconds == 0
                ? L10n.tr("tunnel.handshake.minutesAgo", defaultValue: "\(minutes)m ago")
                : L10n.tr("tunnel.handshake.minutesSeconds", defaultValue: "\(minutes)m \(seconds)s")
        case 3600 ..< 86400:
            let hours = elapsed / 3600
            let minutes = (elapsed % 3600) / 60
            return minutes == 0
                ? L10n.tr("tunnel.handshake.hoursAgo", defaultValue: "\(hours)h ago")
                : L10n.tr("tunnel.handshake.hoursMinutes", defaultValue: "\(hours)h \(minutes)m")
        default:
            let days = elapsed / 86400
            return L10n.tr("tunnel.handshake.daysAgo", defaultValue: "\(days)d ago")
        }
    }
}
