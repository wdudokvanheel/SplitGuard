// SPDX-License-Identifier: MIT

import Foundation
import Observation
import SplitGuardCore
import WireGuardEngine

struct DetailFieldRow: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    let isMonospaced: Bool
    let isCopyable: Bool
}

struct PeerDisplaySnapshot: Identifiable, Equatable {
    let id: String
    let index: Int
    let configRows: [DetailFieldRow]
    let healthState: TunnelHealthState?
    let rxBytesText: String?
    let txBytesText: String?
    let lastHandshakeText: String?

    var hasLiveStats: Bool {
        healthState != nil || rxBytesText != nil || txBytesText != nil || lastHandshakeText != nil
    }
}

@MainActor
@Observable
final class TunnelDetailViewModel {
    let tunnel: Tunnel
    private weak var store: TunnelStore?

    private(set) var interfaceRows: [DetailFieldRow] = []
    private(set) var peers: [PeerDisplaySnapshot] = []
    private(set) var onDemandInterfaceSummary: String = ""
    private(set) var onDemandSSIDSummary: String?
    private(set) var onDemandSelectedSSIDs: [String] = []
    private(set) var splitDNSConfiguration: SplitDNSConfiguration = .allDomains
    private(set) var tunnelOptions: TunnelOptions = .default
    private(set) var localSettings: TunnelLocalSettings = .default
    private(set) var deviceStatus: DeviceStatus?
    private(set) var dnsServers: [IPAddress] = []
    private(set) var splitDNSWarnings: [SplitDNSConfiguration.ValidationWarning] = []
    private(set) var totalRxBytes: UInt64 = 0
    private(set) var totalTxBytes: UInt64 = 0
    private(set) var latestHandshakeText: String?
    private(set) var hasAnyLiveStats = false

    private var pollingTask: Task<Void, Never>?

    var healthState: TunnelHealthState? {
        TunnelHealthState.evaluate(
            killSwitchEnabled: tunnelOptions.killSwitch.isEnabled,
            deviceStatus: deviceStatus
        )
    }

    var killSwitchBlockState: KillSwitchBlockState? {
        if case .blocking(let state) = healthState {
            return state
        }
        return nil
    }

    init(tunnel: Tunnel, store: TunnelStore) {
        self.tunnel = tunnel
        self.store = store
        rebuildSnapshots(now: Date())
    }

    var primaryEndpoint: String? {
        tunnel.primaryEndpoint
    }

    var totalRxFormatted: String {
        Self.formatBytes(totalRxBytes)
    }

    var totalTxFormatted: String {
        Self.formatBytes(totalTxBytes)
    }

    func refreshStaticConfiguration() {
        rebuildSnapshots(now: Date())
    }

    func apply(deviceStatus: DeviceStatus?, now: Date = Date()) {
        self.deviceStatus = deviceStatus
        rebuildSnapshots(now: now)
    }

    func updatePolling(for status: TunnelStatus, isVisible: Bool) {
        guard isVisible else {
            stopPolling()
            return
        }
        if status == .active {
            startPollingIfNeeded()
        } else {
            stopPolling()
            deviceStatus = nil
            refreshStaticConfiguration()
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func pollRuntimeStatusOnce(now: Date? = nil) async {
        guard let store else { return }
        let fetchedStatus = await store.fetchDeviceStatus(for: tunnel)
        guard !Task.isCancelled else { return }
        apply(deviceStatus: fetchedStatus, now: now ?? Date())
    }

    private func startPollingIfNeeded() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollRuntimeStatusOnce()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func rebuildSnapshots(now: Date) {
        let profile = tunnel.profile
        interfaceRows = buildInterfaceRows(from: profile.interface, deviceStatus: deviceStatus)
        peers = buildPeerSnapshots(from: profile.peers, deviceStatus: deviceStatus, now: now)
        updateLiveSummary(from: deviceStatus, now: now)
        updateOnDemandSummary(from: tunnel.onDemandPolicy)
        updateSplitDNSSummary(from: profile)
        tunnelOptions = profile.options
        localSettings = tunnel.localSettings
    }

    private func updateLiveSummary(from status: DeviceStatus?, now: Date) {
        guard let status else {
            totalRxBytes = 0
            totalTxBytes = 0
            hasAnyLiveStats = false
            latestHandshakeText = nil
            return
        }

        totalRxBytes = status.peers.reduce(0) { $0 &+ $1.rxBytes }
        totalTxBytes = status.peers.reduce(0) { $0 &+ $1.txBytes }
        hasAnyLiveStats = status.peers.contains {
            $0.rxBytes > 0 || $0.txBytes > 0 || $0.lastHandshake != nil
        }
        latestHandshakeText = status.peers
            .compactMap(\.lastHandshake)
            .max()
            .map { Self.formatHandshake($0, relativeTo: now) }
    }

    private func updateOnDemandSummary(from policy: OnDemandPolicy) {
        onDemandInterfaceSummary = policy.interfaceDescription
        let ssidDescription = policy.ssidDescription
        onDemandSSIDSummary = ssidDescription.isEmpty ? nil : ssidDescription
        onDemandSelectedSSIDs = policy.selectedSSIDs
    }

    private func updateSplitDNSSummary(from profile: TunnelProfile) {
        splitDNSConfiguration = profile.splitDNS
        dnsServers = profile.interface.dnsServers
        splitDNSWarnings = profile.splitDNS.validationWarnings(for: profile)
    }
}

extension TunnelDetailViewModel {
    static func formatBytes(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .binary))
    }

    static func formatHandshake(_ date: Date, relativeTo now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 0 {
            return String(
                localized: "tunnel.handshake.clockBackward",
                defaultValue: "(System clock wound backwards)"
            )
        }
        if elapsed < 1 {
            return String(localized: "tunnel.handshake.now", defaultValue: "Now")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

private extension TunnelDetailViewModel {
    func buildInterfaceRows(
        from interface: InterfaceConfiguration,
        deviceStatus: DeviceStatus?
    ) -> [DetailFieldRow] {
        var rows: [DetailFieldRow] = []

        if let publicKey = (try? interface.privateKey.publicKey())?.base64, !publicKey.isEmpty {
            rows.append(makeInterfaceRow(.publicKey, value: publicKey))
        }
        if !interface.addresses.isEmpty {
            rows.append(makeInterfaceRow(
                .addresses,
                value: interface.addresses.map(\.description).joined(separator: ", ")
            ))
        }
        let livePort = deviceStatus.flatMap { $0.listenPort > 0 ? $0.listenPort : nil }
        if let listenPort = livePort ?? interface.listenPort {
            rows.append(makeInterfaceRow(.listenPort, value: String(listenPort)))
        }
        if let mtu = interface.mtu {
            rows.append(makeInterfaceRow(.mtu, value: String(mtu)))
        }

        var dnsEntries = interface.dnsServers.map(\.description)
        dnsEntries.append(contentsOf: interface.dnsSearch)
        if !dnsEntries.isEmpty {
            rows.append(makeInterfaceRow(.dns, value: dnsEntries.joined(separator: ", ")))
        }

        return rows
    }

    func makeInterfaceRow(_ field: InterfaceField, value: String) -> DetailFieldRow {
        DetailFieldRow(
            id: "iface-\(field.localizedTitle)",
            label: field.localizedTitle,
            value: value,
            isMonospaced: true,
            isCopyable: true
        )
    }

    func buildPeerSnapshots(
        from configuredPeers: [PeerConfiguration],
        deviceStatus: DeviceStatus?,
        now: Date
    ) -> [PeerDisplaySnapshot] {
        let livePeersByKey = Dictionary(
            uniqueKeysWithValues: (deviceStatus?.peers ?? []).map { ($0.publicKey, $0) }
        )

        return configuredPeers.enumerated().map { index, peer in
            let livePeer = livePeersByKey[peer.publicKey]
            let rows = buildPeerConfigRows(for: peer, index: index, liveEndpoint: livePeer?.endpoint)

            let rxText: String?
            let txText: String?
            let handshakeText: String?
            if let livePeer {
                let hasActivity = livePeer.rxBytes > 0 || livePeer.txBytes > 0 || livePeer.lastHandshake != nil
                rxText = hasActivity ? Self.formatBytes(livePeer.rxBytes) : nil
                txText = hasActivity ? Self.formatBytes(livePeer.txBytes) : nil
                handshakeText = livePeer.lastHandshake.map { Self.formatHandshake($0, relativeTo: now) }
            } else {
                rxText = nil
                txText = nil
                handshakeText = nil
            }

            return PeerDisplaySnapshot(
                id: peer.publicKey.base64,
                index: index,
                configRows: rows,
                healthState: livePeer.map(TunnelHealthState.init(peer:)),
                rxBytesText: rxText,
                txBytesText: txText,
                lastHandshakeText: handshakeText
            )
        }
    }

    func buildPeerConfigRows(
        for peer: PeerConfiguration,
        index: Int,
        liveEndpoint: IPEndpoint?
    ) -> [DetailFieldRow] {
        var rows: [DetailFieldRow] = [
            makePeerRow(.publicKey, index: index, value: peer.publicKey.base64, monospaced: true, copyable: true)
        ]

        if peer.presharedKey != nil {
            rows.append(makePeerRow(
                .presharedKey,
                index: index,
                value: String(localized: "tunnel.peer.presharedKey.enabled", defaultValue: "enabled"),
                monospaced: false,
                copyable: false
            ))
        }
        if let endpointText = liveEndpoint?.description ?? peer.endpoint?.description {
            rows.append(makePeerRow(.endpoint, index: index, value: endpointText, monospaced: true, copyable: true))
        }
        if !peer.allowedIPs.isEmpty {
            rows.append(makePeerRow(
                .allowedIPs,
                index: index,
                value: peer.allowedIPs.map(\.description).joined(separator: ", "),
                monospaced: true,
                copyable: true
            ))
        }
        if let keepalive = peer.persistentKeepalive {
            rows.append(makePeerRow(
                .persistentKeepalive,
                index: index,
                value: String(
                    localized: "tunnel.peer.persistentKeepalive.value",
                    defaultValue: "every \(Int(keepalive)) seconds"
                ),
                monospaced: false,
                copyable: true
            ))
        }

        return rows
    }

    func makePeerRow(
        _ field: PeerField,
        index: Int,
        value: String,
        monospaced: Bool,
        copyable: Bool
    ) -> DetailFieldRow {
        DetailFieldRow(
            id: "peer-\(index)-\(field.localizedTitle)",
            label: field.localizedTitle,
            value: value,
            isMonospaced: monospaced,
            isCopyable: copyable
        )
    }
}
