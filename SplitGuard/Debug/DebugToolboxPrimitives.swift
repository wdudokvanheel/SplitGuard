#if DEBUG
import Foundation
import SwiftUI
import WireGuardEngine

struct DebugTunnelCountSummary: View {
    let store: TunnelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("CURRENT TUNNELS (\(store.tunnels.count))")
                .font(SGTypography.metricLabel)
                .foregroundStyle(SGColor.textSecondary)
            if store.tunnels.isEmpty {
                Text("None")
                    .font(SGTypography.monoCompact)
                    .foregroundStyle(SGColor.textTertiary)
            } else {
                Text(store.tunnels.map(\.name).joined(separator: ", "))
                    .font(SGTypography.monoCompact)
                    .foregroundStyle(SGColor.textPrimary)
            }
        }
        .padding(SGSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SGColor.surfaceElevated)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
    }
}

struct DebugTunnelPickerStrip: View {
    let store: TunnelStore
    @Binding var selectedTunnelID: Tunnel.ID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SGSpacing.xSmall) {
                ForEach(store.tunnels) { tunnel in
                    let isSelected = (selectedTunnelID ?? store.activeTunnel?.id ?? store.tunnels.first?.id) == tunnel.id
                    Button {
                        selectedTunnelID = tunnel.id
                    } label: {
                        Text(tunnel.name)
                            .font(SGTypography.badge)
                            .foregroundStyle(isSelected ? SGColor.inkOnPop : SGColor.textPrimary)
                            .padding(.horizontal, SGSpacing.xSmall)
                            .padding(.vertical, 6)
                            .background(isSelected ? SGColor.popYellow : SGColor.surfaceElevated)
                            .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct DebugActionButton: View {
    let title: String
    let icon: String
    var fill: Color = SGColor.popYellow
    var foreground: Color = SGColor.inkOnPop
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.black))
                Text(title)
                    .font(SGTypography.displayCompact)
                    .tracking(0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, SGSpacing.small)
            .padding(.vertical, 10)
        }
        .buttonStyle(
            BrutalistButtonStyle(
                fill: fill,
                foreground: foreground,
                borderWidth: SGBorder.regular,
                shadowOffset: SGShadow.small,
                fullWidth: true,
                showGrain: true
            )
        )
    }
}

enum DebugSampleConfigFactory {
    static func sampleConfigText() -> String {
        let privKey = WireGuardPrivateKey.generate().base64
        let pubKey = (try? WireGuardPrivateKey.generate().publicKey().base64)
            ?? "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        return """
        # SplitGuard: split-dns-mode = only-domains
        # SplitGuard: split-dns-domains = internal.example
        # SplitGuard: kill-switch = on
        # SplitGuard: kill-switch-allow-lan = on
        [Interface]
        PrivateKey = \(privKey)
        Address = 10.99.0.2/32
        DNS = 10.99.0.1

        [Peer]
        PublicKey = \(pubKey)
        Endpoint = vpn.example.com:51820
        AllowedIPs = 0.0.0.0/0
        PersistentKeepalive = 25
        """
    }

    static func writeSampleConfFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("splitguard-sample.conf")
        do {
            try Data(sampleConfigText().utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
#endif
