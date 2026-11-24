#if DEBUG
import SplitGuardCore
import SwiftUI
import UIKit

// MARK: - Manual Steps 4 to 7 Toolboxes

struct OnDemandToolboxView: View {
    let store: TunnelStore
    let onAction: (DebugWizardAction) -> Void
    @State private var noteText: String?

    var body: some View {
        if let serverFixture = DebugBundledFixtures.serverTest() {
            DebugActionButton(title: "LOAD SERVERTEST FOR ON-DEMAND", icon: "wifi", fill: SGColor.popBlue) {
                Task {
                    do {
                        let tunnel = try await DebugBundledFixtures.ensureLoaded(
                            fixture: serverFixture,
                            named: "ServerTest-OnDemand",
                            in: store
                        )
                        noteText = "Loaded \(tunnel.name). Tap Edit Rules below to configure Wi-Fi / Cellular / SSID."
                    } catch {
                        noteText = "Error: \(error.localizedDescription)"
                    }
                }
            }
        }

        if let noteText {
            Text(noteText)
                .font(SGTypography.monoCompact)
                .foregroundStyle(SGColor.textSecondary)
        }

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
        if store.tunnels.isEmpty, !DebugBundledFixtures.allAvailable().isEmpty {
            DebugActionButton(title: "ENSURE BUNDLED TUNNELS LOADED", icon: "tray.and.arrow.down.fill", fill: SGColor.popBlue) {
                Task {
                    for fixture in DebugBundledFixtures.allAvailable() {
                        _ = try? await DebugBundledFixtures.ensureLoaded(
                            fixture: fixture,
                            named: fixture.displayName,
                            in: store
                        )
                    }
                }
            }
        }

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
    @State private var noteText: String?

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

        if let certFixture = DebugBundledFixtures.testCert() {
            DebugActionButton(title: "CREATE DISPOSABLE TESTCERT TUNNEL", icon: "plus.square.fill", fill: SGColor.popGreen) {
                Task {
                    do {
                        let tunnel = try await DebugBundledFixtures.ensureLoaded(
                            fixture: certFixture,
                            named: "SettingsSyncTest",
                            in: store
                        )
                        noteText = "Created '\(tunnel.name)'. Modify or delete it in iOS Settings -> VPN."
                    } catch {
                        noteText = "Error: \(error.localizedDescription)"
                    }
                }
            }
        }

        if let noteText {
            Text(noteText)
                .font(SGTypography.monoCompact)
                .foregroundStyle(SGColor.textSecondary)
        }

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

struct QuickActionsAndLogToolboxView: View {
    let store: TunnelStore
    let onAction: (DebugWizardAction) -> Void

    @State private var shortcutTitles: [String] = []
    @State private var recentNames: [String] = []
    @State private var logStatusText = "Tap Refresh to inspect log files."

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Tunnels: \(recentNames.isEmpty ? "None yet" : recentNames.joined(separator: ", "))")
                .font(SGTypography.monoCompact)
                .foregroundStyle(SGColor.textPrimary)
            Text("Registered Shortcuts: \(shortcutTitles.isEmpty ? "None" : shortcutTitles.joined(separator: ", "))")
                .font(SGTypography.monoCompact)
                .foregroundStyle(SGColor.textSecondary)
            Text(logStatusText)
                .font(SGTypography.monoCompact)
                .foregroundStyle(SGColor.textSecondary)
        }
        .padding(SGSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SGColor.surfaceElevated)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))

        DebugActionButton(title: "REFRESH QUICK ACTIONS", icon: "bolt.horizontal.circle", fill: SGColor.popYellow) {
            store.updateQuickActions()
            refreshSnapshot()
        }

        HStack(spacing: SGSpacing.xSmall) {
            DebugActionButton(title: "WRITE APP LOG LINE", icon: "pencil.line", fill: SGColor.popBlue) {
                Log.info("Debug Verification Wizard marker (\(Int(Date().timeIntervalSince1970)))")
                Log.flush()
                refreshSnapshot()
            }
            DebugActionButton(title: "OPEN LOG VIEWER", icon: "doc.text.fill", fill: SGColor.popGreen) {
                onAction(.openLogViewer)
            }
        }
        .onAppear { refreshSnapshot() }
    }

    private func refreshSnapshot() {
        recentNames = RecentTunnelsTracker.recentlyActivatedTunnelNames(
            limit: 4,
            userDefaults: store.recentTunnelsUserDefaults
        )
        shortcutTitles = (UIApplication.shared.shortcutItems ?? []).map(\.localizedTitle)
        guard let dir = AppGroup.containerURL() else {
            logStatusText = "App Group container unavailable."
            return
        }
        let fileManager = FileManager.default
        let appPath = AppGroup.appLogURL(inDirectory: dir).path
        let netPath = AppGroup.tunnelLogURL(inDirectory: dir).path
        let appSize = (try? fileManager.attributesOfItem(atPath: appPath)[.size] as? NSNumber)?.intValue
        let netSize = (try? fileManager.attributesOfItem(atPath: netPath)[.size] as? NSNumber)?.intValue
        let mergedCount = MergedLogReader(directoryURL: dir).readAll().count
        logStatusText = "app.log: \(appSize.map { "\($0) B" } ?? "missing") | "
            + "tunnel.log: \(netSize.map { "\($0) B" } ?? "missing") | Merged: \(mergedCount)"
    }
}
#endif
