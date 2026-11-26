import SwiftUI
import UIKit

struct TunnelDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let store: TunnelStore
    let tunnel: Tunnel
    let onEdit: () -> Void
    let onDeleted: () -> Void

    @State private var viewModel: TunnelDetailViewModel
    @State private var isVisible = false
    @State private var showDeleteConfirmation = false
    @State private var copiedFieldID: String?

    init(
        store: TunnelStore,
        tunnel: Tunnel,
        onEdit: @escaping () -> Void,
        onDeleted: @escaping () -> Void
    ) {
        self.store = store
        self.tunnel = tunnel
        self.onEdit = onEdit
        self.onDeleted = onDeleted
        _viewModel = State(initialValue: TunnelDetailViewModel(tunnel: tunnel, store: store))
    }

    private var displayState: TunnelDisplayState {
        store.displayState(for: tunnel, healthState: viewModel.healthState)
    }

    private var heroHandshakeText: String {
        if let latest = viewModel.latestHandshakeText {
            return latest
        }
        switch viewModel.healthState {
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

    var body: some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: tunnel.name,
                enableSwipeBack: true,
                leading: {
                    BrutalistBackButton {
                        dismiss()
                    }
                },
                trailing: {
                    BrutalistHeaderButton(
                        title: L10n.tr("action.edit", defaultValue: "Edit"),
                        systemImage: "pencil",
                        fill: SGColor.popYellow,
                        foreground: SGColor.inkOnPop
                    ) {
                        Task {
                            let reason = L10n.tr(
                                "privacy.viewPrivateKeys",
                                defaultValue: "Authenticate to view tunnel private keys."
                            )
                            if await PrivateDataConfirmation.confirmAccess(reason: reason) {
                                onEdit()
                            }
                        }
                    }
                }
            )

            ScrollView {
                VStack(spacing: SGSpacing.medium) {
                    TunnelDetailHeroCard(
                        tunnelName: tunnel.name,
                        endpoint: viewModel.primaryEndpoint,
                        displayState: displayState,
                        isFavorite: store.isFavorite(tunnel),
                        rxText: viewModel.hasAnyLiveStats ? viewModel.totalRxFormatted : "0 B",
                        txText: viewModel.hasAnyLiveStats ? viewModel.totalTxFormatted : "0 B",
                        handshakeText: heroHandshakeText,
                        onToggle: { isOn in
                            Task {
                                await store.setTunnelActive(isOn, for: tunnel)
                            }
                        },
                        onToggleFavorite: {
                            withAnimation(.snappy(duration: 0.2)) {
                                store.toggleFavorite(tunnel)
                            }
                        }
                    )

                    if !viewModel.interfaceRows.isEmpty {
                        brutalistFieldSection(
                            title: L10n.tr("tunnel.section.interface", defaultValue: "Interface"),
                            rows: viewModel.interfaceRows
                        )
                    }

                    SplitDNSDetailCard(
                        splitDNS: viewModel.splitDNSConfiguration,
                        dnsServers: viewModel.dnsServers,
                        warnings: viewModel.splitDNSWarnings,
                        isTunnelActive: displayState.status == .active
                    )

                    ForEach(viewModel.peers) { peer in
                        peerCard(peer)
                    }

                    TunnelDetailOnDemandCard(
                        interfaceSummary: viewModel.onDemandInterfaceSummary,
                        ssidSummary: viewModel.onDemandSSIDSummary,
                        selectedSSIDs: viewModel.onDemandSelectedSSIDs
                    )

                    TunnelDetailKillSwitchCard(
                        isEnabled: viewModel.tunnelOptions.killSwitch.isEnabled,
                        allowLocalNetwork: viewModel.tunnelOptions.killSwitch.allowLocalNetwork
                    )

                    TunnelDetailHealthAlertsCard(
                        healthAlerts: viewModel.localSettings.healthAlerts
                    )

                    deleteButton
                }
                .padding(.horizontal, SGSpacing.medium)
                .padding(.top, SGSpacing.medium)
                .padding(.bottom, SGSpacing.xxLarge)
            }
            .background(SGColor.surfacePrimary.ignoresSafeArea())
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
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
        .onChange(of: store.language) { _, _ in
            viewModel.refreshStaticConfiguration()
        }
        .confirmationDialog(
            L10n.tr("tunnel.delete.confirm", defaultValue: "Delete this tunnel?"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("action.delete", defaultValue: "Delete"), role: .destructive) {
                Task {
                    let succeeded = await store.delete(tunnel: tunnel)
                    if succeeded {
                        onDeleted()
                    }
                }
            }
            Button(L10n.tr("action.cancel", defaultValue: "Cancel"), role: .cancel) {}
        }
    }
}

private extension TunnelDetailView {
    func peerSectionTitle(for peer: PeerDisplaySnapshot) -> String {
        if viewModel.peers.count > 1 {
            let number = peer.index + 1
            return L10n.tr("tunnel.section.peerNumbered", defaultValue: "Peer \(number)")
        }
        return L10n.tr("tunnel.section.peer", defaultValue: "Peer")
    }

    func brutalistFieldSection(title: String, rows: [DetailFieldRow]) -> some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: title)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    detailRow(row)
                    if index < rows.count - 1 {
                        Rectangle().fill(SGColor.borderSubtle).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, SGSpacing.medium)
            .padding(.vertical, SGSpacing.xSmall)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    func peerCard(_ peer: PeerDisplaySnapshot) -> some View {
        let peerHealth = displayState.status == .active ? peer.healthState : nil
        return VStack(spacing: 0) {
            BrutalistSectionBar(
                title: peerSectionTitle(for: peer),
                trailingText: peerHealth?.shortLabel,
                trailingFill: peerHealth?.badgeColor ?? SGColor.popYellow,
                trailingForeground: (peerHealth?.isNeutral ?? false) ? SGColor.textPrimary : SGColor.inkOnPop
            )
            if let peerHealth, let detail = peerHealth.detailMessage {
                TunnelHealthBannerStrip(health: peerHealth, message: detail)
                Rectangle().fill(SGColor.borderInk).frame(height: SGBorder.thin)
            }
            VStack(spacing: 0) {
                if displayState.status == .active || peer.hasLiveStats {
                    peerTransferStrip(peer)
                    Rectangle().fill(SGColor.borderInk).frame(height: SGBorder.thin)
                }
                ForEach(Array(peer.configRows.enumerated()), id: \.element.id) { index, row in
                    detailRow(row)
                    if index < peer.configRows.count - 1 {
                        Rectangle().fill(SGColor.borderSubtle).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, SGSpacing.medium)
            .padding(.vertical, SGSpacing.xSmall)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    var deleteButton: some View {
        Button {
            showDeleteConfirmation = true
        } label: {
            HStack(spacing: SGSpacing.xSmall) {
                Image(systemName: "trash.fill")
                    .font(.subheadline.weight(.bold))
                Text(L10n.tr("tunnel.delete", defaultValue: "Delete tunnel").uppercased())
                    .font(SGTypography.displayButton)
                    .tracking(1.0)
            }
            .padding(.vertical, 12)
        }
        .buttonStyle(
            BrutalistButtonStyle(
                fill: SGColor.popRed,
                foreground: SGColor.pureWhite,
                borderWidth: SGBorder.regular,
                shadowOffset: SGShadow.medium,
                fullWidth: true,
                showGrain: true
            )
        )
        .padding(.top, SGSpacing.xSmall)
    }

    func peerTransferStrip(_ peer: PeerDisplaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
            metricLine(
                label: L10n.tr("tunnel.peer.rxBytes", defaultValue: "Data received"),
                value: peer.rxBytesText ?? "0 B",
                accent: SGColor.popPurple
            )
            metricLine(
                label: L10n.tr("tunnel.peer.txBytes", defaultValue: "Data sent"),
                value: peer.txBytesText ?? "0 B",
                accent: SGColor.popGreen
            )
            metricLine(
                label: L10n.tr("tunnel.peer.lastHandshake", defaultValue: "Latest handshake"),
                value: peer.lastHandshakeText ?? L10n.tr(
                    "tunnel.handshake.noHandshakeYet",
                    defaultValue: "No handshake yet"
                ),
                accent: SGColor.popYellow
            )
        }
        .padding(.vertical, SGSpacing.xSmall)
    }

    func metricLine(label: String, value: String, accent: Color) -> some View {
        HStack(spacing: SGSpacing.xSmall) {
            Rectangle()
                .fill(accent)
                .frame(width: 8, height: 8)
                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
            Text(label)
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textSecondary)
            Spacer()
            Text(value)
                .font(SGTypography.metricValue)
                .foregroundStyle(SGColor.textPrimary)
                .contentTransition(.numericText())
        }
    }

    @ViewBuilder
    func detailRow(_ row: DetailFieldRow) -> some View {
        let content = VStack(alignment: .leading, spacing: SGSpacing.xxSmall) {
            HStack {
                Text(row.label.uppercased())
                    .font(SGTypography.metricLabel)
                    .tracking(0.6)
                    .foregroundStyle(SGColor.textSecondary)
                Spacer()
                if copiedFieldID == row.id {
                    Text(L10n.tr("common.copied", defaultValue: "Copied").uppercased())
                        .font(SGTypography.metricLabel)
                        .foregroundStyle(SGColor.inkOnPop)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SGColor.popGreen)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
                        .transition(.scale.combined(with: .opacity))
                } else if row.isCopyable {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(SGColor.textTertiary)
                }
            }
            Text(row.value)
                .font(row.isMonospaced ? SGTypography.monoValue : SGTypography.body)
                .foregroundStyle(SGColor.textPrimary)
                .textSelection(.enabled)
        }
        .padding(.vertical, SGSpacing.xSmall)

        if row.isCopyable {
            Button { copyValue(row) } label: {
                content.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    func copyValue(_ row: DetailFieldRow) {
        UIPasteboard.general.string = row.value
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.16)) { copiedFieldID = row.id }
        let targetID = row.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedFieldID == targetID {
                withAnimation(.easeInOut(duration: 0.2)) { copiedFieldID = nil }
            }
        }
    }
}
