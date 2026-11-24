#if DEBUG
import SplitGuardCore
import SwiftUI
import UIKit

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
            BrutalistSectionBar(title: "Supplied Configs & Shortcuts")

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
        case .importFilesAndAirDrop:
            ImportConfToolboxView(store: store, onAction: onAction)
        case .importQRCode:
            ImportQRToolboxView(store: store, onAction: onAction)
        case .physicalSplitDNSAndKillSwitch:
            PhysicalSplitDNSAndKillSwitchToolboxView(store: store, onAction: onAction)
        case .onDemandNetworkSwitch:
            OnDemandToolboxView(store: store, onAction: onAction)
        case .deviceAuthAndZipExport:
            AuthAndExportToolboxView(store: store, onAction: onAction)
        case .externalIOSSettingsChanges:
            ExternalSettingsToolboxView(store: store)
        case .quickActionsAndLogViewer:
            QuickActionsAndLogToolboxView(store: store, onAction: onAction)
        }
    }
}

// MARK: - Manual Steps 1 to 3 Toolboxes

private struct ImportConfToolboxView: View {
    let store: TunnelStore
    let onAction: (DebugWizardAction) -> Void

    var body: some View {
        DebugTunnelCountSummary(store: store)

        DebugActionButton(title: "PICK .CONF FILE(S)", icon: "doc.badge.plus", fill: SGColor.popGreen) {
            onAction(.openFileImporter)
        }

        let fixtures = DebugBundledFixtures.allAvailable()
        if fixtures.isEmpty {
            DebugActionButton(title: "SHARE SAMPLE .CONF TO FILES", icon: "square.and.arrow.up", fill: SGColor.popBlue) {
                if let url = DebugSampleConfigFactory.writeSampleConfFile() {
                    onAction(.shareFile(url))
                }
            }
        } else {
            ForEach(fixtures) { fixture in
                DebugActionButton(
                    title: "SHARE \(fixture.fileName.uppercased()) TO FILES",
                    icon: "square.and.arrow.up",
                    fill: SGColor.popBlue
                ) {
                    if let url = DebugBundledFixtures.writeTempConfFile(for: fixture) {
                        onAction(.shareFile(url))
                    }
                }
            }
        }
    }
}

private struct ImportQRToolboxView: View {
    let store: TunnelStore
    let onAction: (DebugWizardAction) -> Void
    @State private var selectedFixtureID: String = DebugBundledFixtures.serverTestBaseName

    private var selectedFixture: DebugBundledFixture? {
        let fixtures = DebugBundledFixtures.allAvailable()
        return fixtures.first { $0.id == selectedFixtureID } ?? fixtures.first
    }

    var body: some View {
        DebugTunnelCountSummary(store: store)

        let fixtures = DebugBundledFixtures.allAvailable()
        if let fixture = selectedFixture {
            if fixtures.count > 1 {
                HStack(spacing: SGSpacing.xSmall) {
                    ForEach(fixtures) { item in
                        Button {
                            selectedFixtureID = item.id
                        } label: {
                            Text(item.displayName.uppercased())
                                .font(SGTypography.badge)
                                .foregroundStyle(item.id == fixture.id ? SGColor.inkOnPop : SGColor.textPrimary)
                                .padding(.horizontal, SGSpacing.small)
                                .padding(.vertical, 6)
                                .background(item.id == fixture.id ? SGColor.popYellow : SGColor.surfaceElevated)
                                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let qrImage = DebugBundledFixtures.qrCodeImage(for: fixture.rawText) {
                HStack {
                    Spacer()
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 170, height: 170)
                        .padding(SGSpacing.xSmall)
                        .background(SGColor.pureWhite)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.regular))
                    Spacer()
                }
            }

            DebugActionButton(
                title: "SHARE \(fixture.displayName.uppercased()) QR IMAGE",
                icon: "square.and.arrow.up",
                fill: SGColor.popBlue
            ) {
                if let pngURL = DebugBundledFixtures.writeQRCodePNG(for: fixture) {
                    onAction(.shareFile(pngURL))
                }
            }
        }

        DebugActionButton(
            title: "OPEN QR SCANNER",
            icon: "qrcode.viewfinder",
            fill: SGColor.popPink,
            foreground: SGColor.pureWhite
        ) {
            onAction(.openQRScanner)
        }
    }
}

private struct PhysicalSplitDNSAndKillSwitchToolboxView: View {
    let store: TunnelStore
    let onAction: (DebugWizardAction) -> Void

    @State private var selectedTunnelID: Tunnel.ID?
    @State private var monitor = TunnelLiveMetricsMonitor()
    @State private var statusNote: String?

    private var selectedTunnel: Tunnel? {
        if let selectedTunnelID, let match = store.tunnel(for: selectedTunnelID) {
            return match
        }
        return store.activeTunnel ?? store.tunnels.first
    }

    var body: some View {
        HStack(spacing: SGSpacing.xSmall) {
            if let certFixture = DebugBundledFixtures.testCert() {
                DebugActionButton(title: "LOAD TESTCERT (SPLIT DNS)", icon: "network", fill: SGColor.popBlue) {
                    Task { await loadSplitDNSFixture(certFixture) }
                }
            }
            if let serverFixture = DebugBundledFixtures.serverTest() {
                DebugActionButton(title: "LOAD SERVERTEST (KS)", icon: "shield.lefthalf.filled", fill: SGColor.popYellow) {
                    Task { await loadKillSwitchFixture(serverFixture) }
                }
            }
        }

        if let statusNote {
            Text(statusNote)
                .font(SGTypography.monoCompact)
                .foregroundStyle(SGColor.textSecondary)
        }

        if !store.tunnels.isEmpty {
            DebugTunnelPickerStrip(store: store, selectedTunnelID: $selectedTunnelID)
        }

        if let tunnel = selectedTunnel {
            let killSwitch = tunnel.options.killSwitch
            VStack(alignment: .leading, spacing: 4) {
                Text("\(tunnel.name) • \(tunnel.status.displayTitle)")
                    .font(SGTypography.bodyBold)
                    .foregroundStyle(SGColor.textPrimary)
                Text(
                    "Kill Switch: \(killSwitch.isEnabled ? "ON" : "OFF") "
                        + "(Allow LAN: \(killSwitch.allowLocalNetwork ? "YES" : "NO")) • "
                        + "Block: \(monitor.killSwitchBlockState?.displayText ?? "Normal")"
                )
                .font(SGTypography.monoCompact)
                .foregroundStyle(SGColor.textSecondary)
            }
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

            SplitDNSRoutingPreviewView(
                splitDNS: tunnel.splitDNS,
                dnsServers: tunnel.profile.interface.dnsServers
            )

            SplitDNSNameTesterView(
                splitDNS: tunnel.splitDNS,
                dnsServers: tunnel.profile.interface.dnsServers,
                isTunnelActive: tunnel.status == .active
            )
        }

        Color.clear.frame(height: 0)
            .onAppear { syncMonitor() }
            .onDisappear { monitor.stop() }
            .onChange(of: selectedTunnel?.id) { _, _ in syncMonitor() }
            .onChange(of: selectedTunnel?.status) { _, _ in syncMonitor() }
    }

    private func loadSplitDNSFixture(_ fixture: DebugBundledFixture) async {
        do {
            let base = try DebugBundledFixtures.parsedProfile(for: fixture)
            let domain = base.peers.first?.endpoint?.hostname ?? "internal.example"
            let splitDNS = SplitDNSConfiguration(
                mode: .onlyDomains,
                domains: [.init(name: domain)],
                exclusions: [.init(name: domain, includesSubdomains: false)]
            )
            let tunnel = try await DebugBundledFixtures.ensureLoaded(
                fixture: fixture,
                named: "TestCert-SplitDNS",
                splitDNS: splitDNS,
                in: store
            )
            selectedTunnelID = tunnel.id
            statusNote = "Loaded \(tunnel.name) (only-domains: \(domain), exact apex excluded)."
        } catch {
            statusNote = "Error: \(error.localizedDescription)"
        }
    }

    private func loadKillSwitchFixture(_ fixture: DebugBundledFixture) async {
        do {
            let tunnel = try await DebugBundledFixtures.ensureLoaded(
                fixture: fixture,
                named: "ServerTest-KillSwitch",
                killSwitch: .init(isEnabled: true, allowLocalNetwork: false),
                in: store
            )
            selectedTunnelID = tunnel.id
            statusNote = "Loaded \(tunnel.name) with strict Kill Switch."
        } catch {
            statusNote = "Error: \(error.localizedDescription)"
        }
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
#endif
