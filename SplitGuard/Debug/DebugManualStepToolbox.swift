#if DEBUG
import SplitGuardCore
import SwiftUI
import UIKit
import WireGuardEngine

enum DebugWizardAction {
    case openFileImporter
    case openQRScanner
    case openPasteConfig
    case openCreateTunnel
    case openEditTunnel(Tunnel)
    case openTunnelDetail(Tunnel)
    case openLogViewer
    case shareFile(URL)
    case shareText(String)
}

struct DebugManualStepToolbox: View {
    @Bindable var model: DebugVerificationWizardModel
    let stepID: ManualStepID
    let store: TunnelStore
    let onAction: (DebugWizardAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: "Live Context & Shortcuts")

            VStack(alignment: .leading, spacing: SGSpacing.small) {
                content
            }
            .padding(SGSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    @ViewBuilder
    private var content: some View {
        switch stepID {
        case .importConfFile:
            ImportConfToolboxView(store: store, onAction: onAction)
        case .importQRCode:
            ImportQRToolboxView(store: store, onAction: onAction)
        case .pasteAndCreateFromScratch:
            PasteAndCreateToolboxView(store: store, onAction: onAction)
        case .connectMetricsDisconnect:
            LiveMetricsToolboxView(store: store, onAction: onAction)
        case .switchAndEditConnected:
            SwitchAndEditToolboxView(store: store, onAction: onAction)
        case .failedStartErrorReporting:
            FailedStartToolboxView(model: model, store: store)
        case .splitDNS:
            SplitDNSToolboxView(store: store, onAction: onAction)
        case .killSwitch:
            KillSwitchToolboxView(store: store, onAction: onAction)
        case .onDemandActivation:
            OnDemandToolboxView(store: store, onAction: onAction)
        case .deviceAuthAndZipExport:
            AuthAndExportToolboxView(store: store, onAction: onAction)
        case .externalIOSSettingsChanges:
            ExternalSettingsToolboxView(store: store)
        case .homeScreenQuickActions:
            QuickActionsToolboxView(store: store)
        case .logViewerAndExport:
            LogViewerToolboxView(onAction: onAction)
        }
    }
}

// MARK: - Steps 1 to 6 Toolboxes

private struct ImportConfToolboxView: View {
    let store: TunnelStore
    let onAction: (DebugWizardAction) -> Void

    var body: some View {
        DebugTunnelCountSummary(store: store)

        DebugActionButton(title: "PICK .CONF FILE(S)", icon: "doc.badge.plus", fill: SGColor.popGreen) {
            onAction(.openFileImporter)
        }

        DebugActionButton(title: "SHARE SAMPLE .CONF TO FILES", icon: "square.and.arrow.up", fill: SGColor.popBlue) {
            if let sampleURL = DebugSampleConfigFactory.writeSampleConfFile() {
                onAction(.shareFile(sampleURL))
            }
        }
    }
}

private struct ImportQRToolboxView: View {
    let store: TunnelStore
    let onAction: (DebugWizardAction) -> Void

    var body: some View {
        DebugTunnelCountSummary(store: store)

        DebugActionButton(title: "OPEN QR SCANNER", icon: "qrcode.viewfinder", fill: SGColor.popPink, foreground: SGColor.pureWhite) {
            onAction(.openQRScanner)
        }
    }
}

private struct PasteAndCreateToolboxView: View {
    let store: TunnelStore
    let onAction: (DebugWizardAction) -> Void
    @State private var copiedSample = false

    var body: some View {
        DebugTunnelCountSummary(store: store)

        DebugActionButton(
            title: copiedSample ? "SAMPLE CONFIG COPIED!" : "COPY SAMPLE WG-QUICK CONFIG",
            icon: "doc.on.doc",
            fill: SGColor.popBlue
        ) {
            UIPasteboard.general.string = DebugSampleConfigFactory.sampleConfigText()
            copiedSample = true
        }

        DebugActionButton(title: "OPEN PASTE CONFIG", icon: "doc.on.clipboard", fill: SGColor.popYellow) {
            onAction(.openPasteConfig)
        }

        DebugActionButton(title: "CREATE FROM SCRATCH", icon: "square.and.pencil", fill: SGColor.popGreen) {
            onAction(.openCreateTunnel)
        }
    }
}

private struct LiveMetricsToolboxView: View {
    let store: TunnelStore
    let onAction: (DebugWizardAction) -> Void

    @State private var selectedTunnelID: Tunnel.ID?
    @State private var monitor = TunnelLiveMetricsMonitor()

    private var selectedTunnel: Tunnel? {
        if let selectedTunnelID, let match = store.tunnel(for: selectedTunnelID) {
            return match
        }
        return store.activeTunnel ?? store.tunnels.first
    }

    var body: some View {
        if store.tunnels.isEmpty {
            Text("No tunnels configured yet. Import or create one first.")
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textSecondary)
        } else {
            DebugTunnelPickerStrip(store: store, selectedTunnelID: $selectedTunnelID)

            if let tunnel = selectedTunnel {
                VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
                    HStack {
                        Text(tunnel.name)
                            .font(SGTypography.bodyBold)
                            .foregroundStyle(SGColor.textPrimary)
                        Spacer()
                        SGStatusBadge(
                            title: tunnel.status.displayTitle,
                            color: tunnel.status == .active ? SGColor.popGreen : SGColor.popYellow,
                            isAnimated: tunnel.status.isTransitioning,
                            isInactive: tunnel.status == .inactive
                        )
                    }

                    Text("Endpoint: \(tunnel.primaryEndpoint ?? "None")")
                        .font(SGTypography.monoCompact)
                        .foregroundStyle(SGColor.textSecondary)
                    Text("RX: \(monitor.rxFormatted)   TX: \(monitor.txFormatted)")
                        .font(SGTypography.monoCompact)
                        .foregroundStyle(SGColor.textPrimary)
                    Text("Last Handshake: \(monitor.handshakeAgeText ?? "None yet")")
                        .font(SGTypography.monoCompact)
                        .foregroundStyle(SGColor.textSecondary)
                }
                .padding(SGSpacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SGColor.surfaceElevated)
                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))

                HStack(spacing: SGSpacing.xSmall) {
                    let isActive = tunnel.status != .inactive
                    DebugActionButton(
                        title: isActive ? "DISCONNECT" : "CONNECT",
                        icon: isActive ? "stop.fill" : "bolt.fill",
                        fill: isActive ? SGColor.popRed : SGColor.popGreen
                    ) {
                        Task { await store.setTunnelActive(!isActive, for: tunnel) }
                    }

                    DebugActionButton(title: "DETAIL", icon: "info.circle", fill: SGColor.popYellow) {
                        onAction(.openTunnelDetail(tunnel))
                    }
                }
            }
        }
        Color.clear.frame(height: 0)
            .onAppear { syncMonitor(visible: true) }
            .onDisappear { monitor.stop() }
            .onChange(of: selectedTunnel?.id) { _, _ in syncMonitor(visible: true) }
            .onChange(of: selectedTunnel?.status) { _, _ in syncMonitor(visible: true) }
    }

    private func syncMonitor(visible: Bool) {
        monitor.update(
            tunnel: selectedTunnel,
            status: selectedTunnel?.status ?? .inactive,
            store: store,
            isVisible: visible
        )
    }
}

private struct SwitchAndEditToolboxView: View {
    let store: TunnelStore
    let onAction: (DebugWizardAction) -> Void

    var body: some View {
        if store.tunnels.isEmpty {
            Text("No tunnels configured yet. Add at least 2 tunnels to test switching.")
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textSecondary)
        } else {
            ForEach(store.tunnels) { tunnel in
                HStack(spacing: SGSpacing.xSmall) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tunnel.name)
                            .font(SGTypography.bodyBold)
                            .foregroundStyle(SGColor.textPrimary)
                        Text(tunnel.status.displayTitle.uppercased())
                            .font(SGTypography.metricLabel)
                            .foregroundStyle(SGColor.textSecondary)
                    }
                    Spacer()
                    let isOn = tunnel.status == .active || tunnel.status == .activating || tunnel.status == .waiting
                    Button(isOn ? "STOP" : "START") {
                        Task { await store.setTunnelActive(!isOn, for: tunnel) }
                    }
                    .font(SGTypography.metricLabel)
                    .padding(.horizontal, SGSpacing.xSmall)
                    .padding(.vertical, 6)
                    .buttonStyle(
                        BrutalistButtonStyle(
                            fill: isOn ? SGColor.popRed : SGColor.popGreen,
                            foreground: SGColor.inkOnPop,
                            borderWidth: SGBorder.thin,
                            shadowOffset: 2
                        )
                    )
                    Button("EDIT") {
                        onAction(.openEditTunnel(tunnel))
                    }
                    .font(SGTypography.metricLabel)
                    .padding(.horizontal, SGSpacing.xSmall)
                    .padding(.vertical, 6)
                    .buttonStyle(
                        BrutalistButtonStyle(
                            fill: SGColor.popYellow,
                            foreground: SGColor.inkOnPop,
                            borderWidth: SGBorder.thin,
                            shadowOffset: 2
                        )
                    )
                }
                .padding(SGSpacing.xSmall)
                .background(SGColor.surfaceElevated)
                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
            }

            if let active = store.activeTunnel {
                DebugActionButton(title: "EDIT ACTIVE TUNNEL (\(active.name))", icon: "pencil", fill: SGColor.popYellow) {
                    onAction(.openEditTunnel(active))
                }
            }
        }
    }
}

private struct FailedStartToolboxView: View {
    @Bindable var model: DebugVerificationWizardModel
    let store: TunnelStore
    @State private var statusMessage: String?

    private var failingTunnel: Tunnel? {
        store.tunnel(named: DebugVerificationNetworkChecks.manualFailingTunnelName)
    }

    var body: some View {
        if let banner = store.lastActivationError {
            VStack(alignment: .leading, spacing: 3) {
                Text("LAST STORE ACTIVATION ERROR (\(banner.tunnelName))")
                    .font(SGTypography.metricLabel)
                    .foregroundStyle(SGColor.inkOnPop)
                Text("\(banner.title): \(banner.message)")
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.inkOnPop)
            }
            .padding(SGSpacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SGColor.popRed)
            .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))
        }

        if let summary = model.startErrorSummary {
            VStack(alignment: .leading, spacing: 3) {
                Text("PROBE RESULT: \(summary.verdictLine)")
                    .font(SGTypography.caption.weight(.bold))
                    .foregroundStyle(SGColor.textPrimary)
                Text("fetchLastDisconnectError: \(summary.fetchLastDisconnectDecoded ?? summary.fetchLastDisconnectRaw)")
                    .font(SGTypography.monoCompact)
                    .foregroundStyle(SGColor.textSecondary)
                Text("IPC fallback: \(summary.ipcDecoded ?? summary.ipcReply)")
                    .font(SGTypography.monoCompact)
                    .foregroundStyle(SGColor.textSecondary)
            }
            .padding(SGSpacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SGColor.surfaceElevated)
            .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
        }

        DebugActionButton(title: "RUN START-ERROR PROBE", icon: "exclamationmark.triangle.fill", fill: SGColor.popYellow) {
            Task { await model.runAutomatedCheck(.startErrorProbe, store: store) }
        }

        if let failingTunnel {
            HStack(spacing: SGSpacing.xSmall) {
                DebugActionButton(title: "ACTIVATE FAILING TUNNEL", icon: "bolt.slash.fill", fill: SGColor.popRed) {
                    Task { await store.setTunnelActive(true, for: failingTunnel) }
                }
                DebugActionButton(title: "DELETE TEST TUNNEL", icon: "trash.fill", fill: SGColor.surfaceElevated) {
                    Task {
                        _ = await DebugVerificationNetworkChecks.removeManualFailingTunnel(in: store)
                        statusMessage = "Removed \(DebugVerificationNetworkChecks.manualFailingTunnelName)."
                    }
                }
            }
        } else {
            DebugActionButton(title: "CREATE FAILING TEST TUNNEL", icon: "plus.square.fill", fill: SGColor.popBlue) {
                Task {
                    do {
                        _ = try await DebugVerificationNetworkChecks.createManualFailingTunnel(in: store)
                        statusMessage = "Created \(DebugVerificationNetworkChecks.manualFailingTunnelName)."
                    } catch {
                        statusMessage = "Failed: \(error.localizedDescription)"
                    }
                }
            }
        }

        if let statusMessage {
            Text(statusMessage)
                .font(SGTypography.monoCompact)
                .foregroundStyle(SGColor.textSecondary)
        }
    }
}
#endif
