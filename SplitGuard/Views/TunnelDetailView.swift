import SwiftUI
import UIKit

struct TunnelDetailView: View {
    let store: TunnelStore
    let tunnel: TunnelContainer
    let onDeleted: () -> Void

    @State private var viewModel: TunnelDetailViewModel
    @State private var isVisible = false
    @State private var showDeleteConfirmation = false
    @State private var showEditSheet = false
    @State private var copiedFieldID: String?

    init(store: TunnelStore, tunnel: TunnelContainer, onDeleted: @escaping () -> Void) {
        self.store = store
        self.tunnel = tunnel
        self.onDeleted = onDeleted
        _viewModel = State(initialValue: TunnelDetailViewModel(tunnel: tunnel))
    }

    private var displayState: TunnelDisplayState {
        store.displayState(for: tunnel)
    }

    var body: some View {
        List {
            Section {
                TunnelHeroCardView(
                    tunnelName: tunnel.name,
                    endpoint: viewModel.primaryEndpoint,
                    displayState: displayState,
                    rxText: viewModel.hasAnyLiveStats ? viewModel.totalRxFormatted : "0 B",
                    txText: viewModel.hasAnyLiveStats ? viewModel.totalTxFormatted : "0 B",
                    handshakeText: viewModel.latestHandshakeText ?? "Pending",
                    onToggle: { isOn in
                        store.setTunnelActive(isOn, for: tunnel)
                    }
                )
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if !viewModel.interfaceRows.isEmpty {
                Section(tr("tunnelSectionTitleInterface")) {
                    ForEach(viewModel.interfaceRows) { row in
                        detailRow(row)
                    }
                }
            }

            SplitDNSDetailSection(
                splitDNS: viewModel.splitDNSConfiguration,
                dnsServers: viewModel.dnsServers,
                warnings: viewModel.splitDNSWarnings,
                isTunnelActive: displayState.status == .active
            )

            ForEach(viewModel.peers) { peer in
                Section(peerSectionTitle(for: peer)) {
                    if displayState.status == .active || peer.hasLiveStats {
                        peerTransferStrip(peer)
                    }
                    ForEach(peer.configRows) { row in
                        detailRow(row)
                    }
                }
            }

            Section(tr("tunnelSectionTitleOnDemand")) {
                LabeledContent(tr("tunnelOnDemandKey"), value: viewModel.onDemandInterfaceSummary)
                if let ssidSummary = viewModel.onDemandSSIDSummary {
                    LabeledContent(tr("tunnelOnDemandSSIDsKey"), value: ssidSummary)
                }
                ForEach(viewModel.onDemandSelectedSSIDs, id: \.self) { ssid in
                    Label(ssid, systemImage: "wifi")
                        .font(SGTypography.subheadline)
                        .foregroundStyle(SGColor.textSecondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        Text(tr("deleteTunnelButtonTitle"))
                            .fontWeight(.medium)
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(tunnel.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    PrivateDataConfirmation.confirmAccess(to: tr("iosViewPrivateData")) {
                        showEditSheet = true
                    }
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            TunnelEditorView(store: store, tunnel: tunnel) { _ in
                viewModel.refreshStaticConfiguration()
            }
        }
        .onAppear {
            isVisible = true
            viewModel.refreshStaticConfiguration()
            viewModel.updatePolling(for: displayState.status, isVisible: true)
        }
        .onDisappear {
            isVisible = false
            viewModel.stopPolling()
        }
        .onChange(of: displayState.status) { _, newStatus in
            viewModel.updatePolling(for: newStatus, isVisible: isVisible)
        }
        .onChange(of: store.revision) { _, _ in
            viewModel.refreshStaticConfiguration()
        }
        .confirmationDialog(
            tr("deleteTunnelConfirmationAlertMessage"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(tr("deleteTunnelConfirmationAlertButtonTitle"), role: .destructive) {
                store.delete(tunnel: tunnel) { succeeded in
                    if succeeded {
                        onDeleted()
                    }
                }
            }
            Button(tr("actionCancel"), role: .cancel) {}
        }
    }

    private func peerSectionTitle(for peer: PeerDisplaySnapshot) -> String {
        if viewModel.peers.count > 1 {
            return "\(tr("tunnelSectionTitlePeer")) \(peer.index + 1)"
        }
        return tr("tunnelSectionTitlePeer")
    }

    private func peerTransferStrip(_ peer: PeerDisplaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
            HStack {
                Label(tr("tunnelPeerRxBytes"), systemImage: "arrow.down")
                    .font(SGTypography.subheadline)
                    .foregroundStyle(SGColor.textSecondary)
                Spacer()
                Text(peer.rxBytesText ?? "0 B")
                    .font(SGTypography.metricValue)
                    .foregroundStyle(SGColor.textPrimary)
            }

            HStack {
                Label(tr("tunnelPeerTxBytes"), systemImage: "arrow.up")
                    .font(SGTypography.subheadline)
                    .foregroundStyle(SGColor.textSecondary)
                Spacer()
                Text(peer.txBytesText ?? "0 B")
                    .font(SGTypography.metricValue)
                    .foregroundStyle(SGColor.textPrimary)
            }

            HStack {
                Label(tr("tunnelPeerLastHandshakeTime"), systemImage: "clock")
                    .font(SGTypography.subheadline)
                    .foregroundStyle(SGColor.textSecondary)
                Spacer()
                Text(peer.lastHandshakeText ?? "No handshake yet")
                    .font(SGTypography.subheadline)
                    .foregroundStyle(peer.lastHandshakeText == nil ? SGColor.textTertiary : SGColor.textPrimary)
            }
        }
        .padding(.vertical, SGSpacing.xxSmall)
    }

    @ViewBuilder
    private func detailRow(_ row: DetailFieldRow) -> some View {
        let content = VStack(alignment: .leading, spacing: SGSpacing.xxSmall) {
            HStack {
                Text(row.label)
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.textSecondary)
                Spacer()
                if copiedFieldID == row.id {
                    Label("Copied", systemImage: "checkmark")
                        .font(SGTypography.metricLabel)
                        .foregroundStyle(SGColor.accent)
                        .transition(.opacity)
                }
            }
            Text(row.value)
                .font(row.isMonospaced ? SGTypography.monoValue : SGTypography.body)
                .foregroundStyle(SGColor.textPrimary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)

        if row.isCopyable {
            Button {
                copyValue(row)
            } label: {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func copyValue(_ row: DetailFieldRow) {
        UIPasteboard.general.string = row.value
        withAnimation(.easeInOut(duration: 0.15)) {
            copiedFieldID = row.id
        }
        let targetID = row.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedFieldID == targetID {
                withAnimation(.easeInOut(duration: 0.2)) {
                    copiedFieldID = nil
                }
            }
        }
    }
}

private struct TunnelHeroCardView: View {
    let tunnelName: String
    let endpoint: String?
    let displayState: TunnelDisplayState
    let rxText: String
    let txText: String
    let handshakeText: String
    let onToggle: (Bool) -> Void

    var body: some View {
        VStack(spacing: SGSpacing.medium) {
            HStack(spacing: SGSpacing.small) {
                ZStack {
                    RoundedRectangle(cornerRadius: SGRadius.medium, style: .continuous)
                        .fill(displayState.statusColor.opacity(0.16))
                        .frame(width: 48, height: 48)
                    Image(systemName: displayState.status.symbolName)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(displayState.statusColor)
                }

                VStack(alignment: .leading, spacing: SGSpacing.xxSmall) {
                    Text(tunnelName)
                        .font(SGTypography.cardTitle)
                        .foregroundStyle(SGColor.textPrimary)
                        .lineLimit(1)

                    SGStatusBadge(
                        title: displayState.statusText,
                        color: displayState.statusColor,
                        isAnimated: displayState.status.isTransitioning
                    )

                    if let endpoint {
                        Text(endpoint)
                            .font(SGTypography.monoCompact)
                            .foregroundStyle(SGColor.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: SGSpacing.xSmall)

                Toggle(
                    isOn: Binding(
                        get: { displayState.isSwitchOn },
                        set: onToggle
                    )
                ) {
                    EmptyView()
                }
                .labelsHidden()
                .tint(displayState.switchTint)
                .disabled(!displayState.isSwitchInteractive)
                .accessibilityLabel("Toggle \(tunnelName)")
            }

            if displayState.status == .active {
                Divider()
                HStack(spacing: SGSpacing.small) {
                    metricTile(
                        title: "Received",
                        value: rxText,
                        systemImage: "arrow.down.circle.fill",
                        tint: SGColor.accent
                    )
                    metricTile(
                        title: "Sent",
                        value: txText,
                        systemImage: "arrow.up.circle.fill",
                        tint: SGColor.statusActive
                    )
                    metricTile(
                        title: "Handshake",
                        value: handshakeText,
                        systemImage: "clock.arrow.circlepath",
                        tint: SGColor.textSecondary
                    )
                }
            }
        }
        .padding(SGSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: SGRadius.large, style: .continuous)
                .fill(SGColor.surfaceCard)
                .overlay(
                    RoundedRectangle(cornerRadius: SGRadius.large, style: .continuous)
                        .strokeBorder(
                            displayState.status == .active
                                ? displayState.statusColor.opacity(0.32)
                                : SGColor.borderSubtle,
                            lineWidth: 1
                        )
                )
        )
    }

    private func metricTile(
        title: String,
        value: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: SGSpacing.xxSmall) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text(title)
                    .font(SGTypography.metricLabel)
                    .foregroundStyle(SGColor.textSecondary)
            }
            Text(value)
                .font(SGTypography.metricValue)
                .foregroundStyle(SGColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
