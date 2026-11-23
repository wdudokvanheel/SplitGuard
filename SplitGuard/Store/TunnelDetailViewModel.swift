import Foundation
import Observation
import WireGuardKit

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
    let rxBytesText: String?
    let txBytesText: String?
    let lastHandshakeText: String?

    var hasLiveStats: Bool {
        rxBytesText != nil || txBytesText != nil || lastHandshakeText != nil
    }
}

@MainActor
@Observable
final class TunnelDetailViewModel {
    private static let interfaceFields: [TunnelViewModel.InterfaceField] = [
        .publicKey, .addresses, .listenPort, .mtu, .dns
    ]

    private static let peerConfigFields: [TunnelViewModel.PeerField] = [
        .publicKey, .preSharedKey, .endpoint, .allowedIPs, .persistentKeepAlive
    ]

    let tunnel: TunnelContainer

    private(set) var interfaceRows: [DetailFieldRow] = []
    private(set) var peers: [PeerDisplaySnapshot] = []
    private(set) var onDemandInterfaceSummary: String = ""
    private(set) var onDemandSSIDSummary: String?
    private(set) var onDemandSelectedSSIDs: [String] = []
    private(set) var totalRxBytes: UInt64 = 0
    private(set) var totalTxBytes: UInt64 = 0
    private(set) var latestHandshakeText: String?
    private(set) var hasAnyLiveStats = false

    private var tunnelViewModel: TunnelViewModel
    private var onDemandViewModel: ActivateOnDemandViewModel
    private var pollingTask: Task<Void, Never>?

    init(tunnel: TunnelContainer) {
        self.tunnel = tunnel
        self.tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnel.tunnelConfiguration)
        self.onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        rebuildSnapshots(from: tunnel.tunnelConfiguration)
    }

    var primaryEndpoint: String? {
        let endpoints = tunnel.tunnelConfiguration?.peers.compactMap(\.endpoint) ?? []
        if endpoints.count == 1 {
            return endpoints[0].stringRepresentation
        }
        if endpoints.count > 1 {
            return "\(endpoints.count) endpoints"
        }
        return nil
    }

    var totalRxFormatted: String {
        Self.formatBytes(totalRxBytes)
    }

    var totalTxFormatted: String {
        Self.formatBytes(totalTxBytes)
    }

    func refreshStaticConfiguration() {
        tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnel.tunnelConfiguration)
        onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        rebuildSnapshots(from: tunnel.tunnelConfiguration)
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
            refreshStaticConfiguration()
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func startPollingIfNeeded() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollRuntimeConfigurationOnce()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func pollRuntimeConfigurationOnce() async {
        let runtimeConfig: TunnelConfiguration? = await withCheckedContinuation { continuation in
            tunnel.getRuntimeTunnelConfiguration { config in
                continuation.resume(returning: config)
            }
        }
        guard !Task.isCancelled, let runtimeConfig else { return }
        tunnelViewModel.applyConfiguration(other: runtimeConfig)
        onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        rebuildSnapshots(from: runtimeConfig)
    }

    private func rebuildSnapshots(from configuration: TunnelConfiguration?) {
        interfaceRows = buildInterfaceRows()
        peers = buildPeerSnapshots()
        updateLiveSummary(from: configuration)
        updateOnDemandSummary()
    }

    private func buildInterfaceRows() -> [DetailFieldRow] {
        Self.interfaceFields.compactMap { field in
            let value = tunnelViewModel.interfaceData[field]
            guard !value.isEmpty else { return nil }
            let isMonospaced = field == .publicKey || field == .addresses || field == .dns ||
                field == .listenPort || field == .mtu
            return DetailFieldRow(
                id: "iface-\(field.localizedUIString)",
                label: field.localizedUIString,
                value: value,
                isMonospaced: isMonospaced,
                isCopyable: true
            )
        }
    }

    private func buildPeerSnapshots() -> [PeerDisplaySnapshot] {
        tunnelViewModel.peersData.enumerated().map { index, peerData in
            let rows: [DetailFieldRow] = Self.peerConfigFields.compactMap { field in
                let rawValue = peerData[field]
                guard !rawValue.isEmpty else { return nil }

                let formattedValue: String
                if field == .persistentKeepAlive {
                    formattedValue = tr(format: "tunnelPeerPersistentKeepaliveValue (%@)", rawValue)
                } else if field == .preSharedKey {
                    formattedValue = tr("tunnelPeerPresharedKeyEnabled")
                } else {
                    formattedValue = rawValue
                }

                let isMonospaced = field == .publicKey || field == .endpoint || field == .allowedIPs
                return DetailFieldRow(
                    id: "peer-\(index)-\(field.localizedUIString)",
                    label: field.localizedUIString,
                    value: formattedValue,
                    isMonospaced: isMonospaced,
                    isCopyable: field != .preSharedKey
                )
            }

            let rxText = peerData[.rxBytes].isEmpty ? nil : peerData[.rxBytes]
            let txText = peerData[.txBytes].isEmpty ? nil : peerData[.txBytes]
            let handshakeText = peerData[.lastHandshakeTime].isEmpty ? nil : peerData[.lastHandshakeTime]
            return PeerDisplaySnapshot(
                id: peerData.publicKey?.base64Key ?? "peer-\(index)",
                index: index,
                configRows: rows,
                rxBytesText: rxText,
                txBytesText: txText,
                lastHandshakeText: handshakeText
            )
        }
    }

    private func updateLiveSummary(from configuration: TunnelConfiguration?) {
        let rawPeers = configuration?.peers ?? []
        totalRxBytes = rawPeers.compactMap(\.rxBytes).reduce(0, +)
        totalTxBytes = rawPeers.compactMap(\.txBytes).reduce(0, +)
        hasAnyLiveStats = rawPeers.contains {
            $0.rxBytes != nil || $0.txBytes != nil || $0.lastHandshakeTime != nil
        }
        latestHandshakeText = peers.first(where: { $0.lastHandshakeText != nil })?.lastHandshakeText
    }

    private func updateOnDemandSummary() {
        onDemandInterfaceSummary = onDemandViewModel.localizedInterfaceDescription
        let ssidDescription = onDemandViewModel.localizedSSIDDescription
        onDemandSSIDSummary = ssidDescription.isEmpty ? nil : ssidDescription
        onDemandSelectedSSIDs = onDemandViewModel.selectedSSIDs
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        switch bytes {
        case 0 ..< 1024:
            return "\(bytes) B"
        case 1024 ..< (1024 * 1024):
            return String(format: "%.2f KiB", Double(bytes) / 1024)
        case (1024 * 1024) ..< (1024 * 1024 * 1024):
            return String(format: "%.2f MiB", Double(bytes) / (1024 * 1024))
        case (1024 * 1024 * 1024) ..< (1024 * 1024 * 1024 * 1024):
            return String(format: "%.2f GiB", Double(bytes) / (1024 * 1024 * 1024))
        default:
            return String(format: "%.2f TiB", Double(bytes) / (1024 * 1024 * 1024 * 1024))
        }
    }
}
