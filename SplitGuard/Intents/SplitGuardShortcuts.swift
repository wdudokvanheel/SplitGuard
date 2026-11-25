// SPDX-License-Identifier: MIT

import AppIntents

struct SplitGuardShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor {
        .navy
    }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectTunnelIntent(),
            phrases: [
                "Connect \(\.$tunnel) in \(.applicationName)",
                "Connect \(\.$tunnel) with \(.applicationName)",
                "Connect a tunnel in \(.applicationName)"
            ],
            shortTitle: "Connect Tunnel",
            systemImageName: "checkmark.shield"
        )
        AppShortcut(
            intent: DisconnectTunnelIntent(),
            phrases: [
                "Disconnect \(\.$tunnel) in \(.applicationName)",
                "Disconnect a tunnel in \(.applicationName)"
            ],
            shortTitle: "Disconnect Tunnel",
            systemImageName: "shield.slash"
        )
        AppShortcut(
            intent: ToggleTunnelIntent(),
            phrases: [
                "Toggle \(\.$tunnel) in \(.applicationName)",
                "Toggle a tunnel in \(.applicationName)"
            ],
            shortTitle: "Toggle Tunnel",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: GetTunnelStatusIntent(),
            phrases: [
                "Get tunnel status in \(.applicationName)",
                "Check VPN status in \(.applicationName)"
            ],
            shortTitle: "Tunnel Status",
            systemImageName: "shield.lefthalf.filled"
        )
        AppShortcut(
            intent: DisconnectActiveTunnelIntent(),
            phrases: [
                "Disconnect active tunnel in \(.applicationName)",
                "Disconnect VPN in \(.applicationName)"
            ],
            shortTitle: "Disconnect Active",
            systemImageName: "xmark.shield"
        )
    }
}
