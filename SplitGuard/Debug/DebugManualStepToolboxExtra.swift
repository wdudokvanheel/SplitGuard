#if DEBUG
import SplitGuardCore
import SwiftUI
import UIKit
import WireGuardEngine

// MARK: - Steps 7 to 13 Toolboxes

struct SplitDNSToolboxView: View {
    let store: TunnelStore
    let onAction: (DebugWizardAction) -> Void
    @State private var selectedTunnelID: Tunnel.ID?

    private var selectedTunnel: Tunnel? {
        if let selectedTunnelID, let match = store.tunnel(for: selectedTunnelID) {
            return match
        }
        return store.activeTunnel ?? store.tunnels.first
    }

    var body: some View {
        if store.tunnels.isEmpty {
            Text("No tunnels available. Import or create a tunnel first.")
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textSecondary)
        } else {
            DebugTunnelPickerStrip(store: store, selectedTunnelID: $selectedTunnelID)

            if let tunnel = selectedTunnel {
                SplitDNSRoutingPreviewView(
                    splitDNS: tunnel.splitDNS,
                    dnsServers: tunnel.profile.interface.dnsServers
                )

                Rectangle()
                    .fill(SGColor.borderSubtle)
                    .frame(height: 1)

                SplitDNSNameTesterView(
                    splitDNS: tunnel.splitDNS,
                    dnsServers: tunnel.profile.interface.dnsServers,
                    isTunnelActive: tunnel.status == .active
                )

                DebugActionButton(title: "EDIT SPLIT DNS (\(tunnel.name))", icon: "pencil", fill: SGColor.popYellow) {
                    onAction(.openEditTunnel(tunnel))
                }
            }
        }
    }
}

struct KillSwitchToolboxView: View {
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
            Text("No tunnels available. Import or create a full-tunnel (0.0.0.0/0) profile first.")
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textSecondary)
        } else {
            DebugTunnelPickerStrip(store: store, selectedTunnelID: $selectedTunnelID)

            if let tunnel = selectedTunnel {
                let killSwitch = tunnel.options.killSwitch
                VStack(alignment: .leading, spacing: 4) {
                    Text("Routes all IPv4 (0.0.0.0/0): \(tunnel.profile.routesAllIPv4Traffic ? "YES" : "NO")")
                    Text("Kill Switch: \(killSwitch.isEnabled ? "ENABLED" : "OFF")")
                    Text("Allow Local Network: \(killSwitch.allowLocalNetwork ? "YES (LAN allowed)" : "NO (Strict)")")
                    Text("Status: \(tunnel.status.displayTitle) | Block State: \(blockStateLabel)")
                }
                .font(SGTypography.monoCompact)
                .foregroundStyle(SGColor.textPrimary)
                .padding(SGSpacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SGColor.surfaceElevated)
                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))

                HStack(spacing: SGSpacing.xSmall) {
                    let isOn = tunnel.status != .inactive
                    DebugActionButton(
                        title: isOn ? "DISCONNECT" : "CONNECT",
                        icon: isOn ? "stop.fill" : "bolt.fill",
                        fill: isOn ? SGColor.popRed : SGColor.popGreen
                    ) {
                        Task { await store.setTunnelActive(!isOn, for: tunnel) }
                    }
                    DebugActionButton(title: "EDIT", icon: "pencil", fill: SGColor.popYellow) {
                        onAction(.openEditTunnel(tunnel))
                    }
                }
            }
        }
        Color.clear.frame(height: 0)
            .onAppear { syncMonitor() }
            .onDisappear { monitor.stop() }
            .onChange(of: selectedTunnel?.id) { _, _ in syncMonitor() }
            .onChange(of: selectedTunnel?.status) { _, _ in syncMonitor() }
    }

    private var blockStateLabel: String {
        monitor.killSwitchBlockState?.displayText ?? "Normal"
    }

    private func syncMonitor() {
        monitor.update(
            tunnel: selectedTunnel,
            status: selectedTunnel?.status ?? .inactive,
            store: store,
            isVisible: true
        )
    }
}

struct OnDemandToolboxView: View {
    let store: TunnelStore
    let onAction: (DebugWizardAction) -> Void

    var body: some View {
        if store.tunnels.isEmpty {
            Text("No tunnels available yet.")
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textSecondary)
        } else {
            ForEach(store.tunnels) { tunnel in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(tunnel.name)
                            .font(SGTypography.bodyBold)
                            .foregroundStyle(SGColor.textPrimary)
                        Spacer()
                        Text(tunnel.status.displayTitle.uppercased())
                            .font(SGTypography.metricLabel)
                            .foregroundStyle(SGColor.textSecondary)
                    }

                    Text(
                        "Policy: \(tunnel.onDemandPolicy.interfaceDescription)"
                            + (tunnel.onDemandPolicy.ssidDescription.isEmpty ? "" : " (\(tunnel.onDemandPolicy.ssidDescription))")
                    )
                    .font(SGTypography.monoCompact)
                    .foregroundStyle(SGColor.textSecondary)

                    HStack(spacing: SGSpacing.xSmall) {
                        if tunnel.hasOnDemandRules {
                            Button(tunnel.isOnDemandEnabled ? "DISABLE ON-DEMAND" : "ENABLE ON-DEMAND") {
                                Task { await store.setTunnelActive(!tunnel.isOnDemandEnabled, for: tunnel) }
                            }
                            .font(SGTypography.metricLabel)
                            .padding(.horizontal, SGSpacing.xSmall)
                            .padding(.vertical, 6)
                            .buttonStyle(
                                BrutalistButtonStyle(
                                    fill: tunnel.isOnDemandEnabled ? SGColor.popRed : SGColor.popGreen,
                                    foreground: SGColor.inkOnPop,
                                    borderWidth: SGBorder.thin,
                                    shadowOffset: 2
                                )
                            )
                        }
                        Button("EDIT RULES") {
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
                }
                .padding(SGSpacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SGColor.surfaceElevated)
                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
            }
        }
    }
}

struct AuthAndExportToolboxView: View {
    let store: TunnelStore
    let onAction: (DebugWizardAction) -> Void

    @State private var authResultText: String?
    @State private var isExporting = false
    @State private var exportErrorText: String?

    var body: some View {
        DebugActionButton(title: "TEST FACE ID / PASSCODE PROMPT", icon: "faceid", fill: SGColor.popPurple) {
            Task {
                let allowed = await PrivateDataConfirmation.confirmAccess(
                    reason: "Debug verification check for device authentication."
                )
                authResultText = allowed ? "Result: AUTHENTICATED" : "Result: CANCELLED / DENIED"
            }
        }

        if let authResultText {
            Text(authResultText)
                .font(SGTypography.monoCompact)
                .foregroundStyle(SGColor.textPrimary)
        }

        DebugActionButton(
            title: isExporting ? "EXPORTING ZIP..." : "EXPORT ALL TUNNELS (.ZIP)",
            icon: "archivebox.fill",
            fill: SGColor.popYellow
        ) {
            exportZipWithAuth()
        }
        .disabled(isExporting)

        if let exportErrorText {
            Text(exportErrorText)
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.popRed)
        }

        if let first = store.tunnels.first {
            DebugActionButton(title: "OPEN DETAIL (\(first.name))", icon: "key.fill", fill: SGColor.popBlue) {
                onAction(.openTunnelDetail(first))
            }
        }
    }

    private func exportZipWithAuth() {
        Task {
            exportErrorText = nil
            let allowed = await PrivateDataConfirmation.confirmAccess(
                reason: "Authenticate to export tunnel private keys."
            )
            guard allowed else {
                authResultText = "Zip export auth: CANCELLED"
                return
            }
            isExporting = true
            defer { isExporting = false }
            do {
                let url = try await store.exportAllTunnelsZip()
                onAction(.shareFile(url))
            } catch {
                exportErrorText = error.localizedDescription
            }
        }
    }
}

struct ExternalSettingsToolboxView: View {
    let store: TunnelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Store Revision: #\(store.revision)  |  Tunnels: \(store.tunnels.count)")
                .font(SGTypography.monoCompact.weight(.bold))
                .foregroundStyle(SGColor.textPrimary)

            ForEach(store.tunnels) { tunnel in
                Text("• \(tunnel.name): \(tunnel.status.displayTitle) (On-Demand: \(tunnel.isOnDemandEnabled ? "ON" : "OFF"))")
                    .font(SGTypography.monoCompact)
                    .foregroundStyle(SGColor.textSecondary)
            }
        }
        .padding(SGSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SGColor.surfaceElevated)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))

        HStack(spacing: SGSpacing.xSmall) {
            DebugActionButton(title: "OPEN IOS SETTINGS", icon: "gear", fill: SGColor.popYellow) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            DebugActionButton(title: "RELOAD NOW", icon: "arrow.clockwise", fill: SGColor.popBlue) {
                Task {
                    await store.reloadFromBackend()
                    await store.refreshStatuses()
                }
            }
        }
    }
}

struct QuickActionsToolboxView: View {
    let store: TunnelStore
    @State private var shortcutTitles: [String] = []
    @State private var recentNames: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Tunnels: \(recentNames.isEmpty ? "None yet" : recentNames.joined(separator: ", "))")
                .font(SGTypography.monoCompact)
                .foregroundStyle(SGColor.textPrimary)
            Text("Registered Shortcuts: \(shortcutTitles.isEmpty ? "None" : shortcutTitles.joined(separator: ", "))")
                .font(SGTypography.monoCompact)
                .foregroundStyle(SGColor.textSecondary)
        }
        .padding(SGSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SGColor.surfaceElevated)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))

        DebugActionButton(title: "REFRESH QUICK ACTIONS", icon: "bolt.horizontal.circle", fill: SGColor.popGreen) {
            store.updateQuickActions()
            refreshSnapshot()
        }
        .onAppear { refreshSnapshot() }
    }

    private func refreshSnapshot() {
        recentNames = RecentTunnelsTracker.recentlyActivatedTunnelNames(
            limit: 4,
            userDefaults: store.recentTunnelsUserDefaults
        )
        shortcutTitles = (UIApplication.shared.shortcutItems ?? []).map(\.localizedTitle)
    }
}

struct LogViewerToolboxView: View {
    let onAction: (DebugWizardAction) -> Void
    @State private var statusText = "Tap Refresh to inspect log files."

    var body: some View {
        Text(statusText)
            .font(SGTypography.monoCompact)
            .foregroundStyle(SGColor.textPrimary)
            .padding(SGSpacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SGColor.surfaceElevated)
            .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))

        HStack(spacing: SGSpacing.xSmall) {
            DebugActionButton(title: "WRITE APP TEST LINE", icon: "pencil.line", fill: SGColor.popBlue) {
                Log.info("Debug Verification Wizard test log marker (\(Int(Date().timeIntervalSince1970)))")
                Log.flush()
                refreshLogStats()
            }
            DebugActionButton(title: "OPEN LOG VIEWER", icon: "doc.text.fill", fill: SGColor.popGreen) {
                onAction(.openLogViewer)
            }
        }
        .onAppear { refreshLogStats() }
    }

    private func refreshLogStats() {
        guard let dir = AppGroup.containerURL() else {
            statusText = "App Group container unavailable."
            return
        }
        let fileManager = FileManager.default
        let appPath = AppGroup.appLogURL(inDirectory: dir).path
        let netPath = AppGroup.tunnelLogURL(inDirectory: dir).path
        let appSize = (try? fileManager.attributesOfItem(atPath: appPath)[.size] as? NSNumber)?.intValue
        let netSize = (try? fileManager.attributesOfItem(atPath: netPath)[.size] as? NSNumber)?.intValue
        let mergedCount = MergedLogReader(directoryURL: dir).readAll().count
        statusText = "app.log: \(appSize.map { "\($0) B" } ?? "missing") | "
            + "tunnel.log: \(netSize.map { "\($0) B" } ?? "missing") | Merged lines: \(mergedCount)"
    }
}
#endif
