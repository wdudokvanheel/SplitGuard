#if DEBUG
import Foundation

enum DebugVerificationCatalog {
    static let manualSteps: [ManualStepDefinition] = [
        ManualStepDefinition(
            id: .importConfFile,
            number: 1,
            title: "Import .conf File",
            subtitle: "Files picker, AirDrop, and Open-In handling",
            instructions: [
                "Tap 'Pick .conf File(s)' below to import from Files, or AirDrop/Open-In a .conf file into SplitGuard.",
                "Verify the imported tunnel appears with the filename as its name and valid keys/endpoint.",
                "Optional: select 2+ .conf files at once (multi-select) and test an invalid .conf to confirm the error alert."
            ],
            whatToVerify: "Valid .conf files import cleanly (including # SplitGuard: directives), and invalid files show a clear alert."
        ),
        ManualStepDefinition(
            id: .importQRCode,
            number: 2,
            title: "Import via QR Code",
            subtitle: "Camera permission, WireGuard QR parsing, and naming prompt",
            instructions: [
                "Tap 'Open QR Scanner' below and grant camera permission if prompted.",
                "Scan a valid WireGuard configuration QR code and enter a unique tunnel name when prompted.",
                "Optional: scan a non-WireGuard QR code and verify the invalid QR alert appears without crashing."
            ],
            whatToVerify: "Scanned WireGuard QR config saves cleanly into the tunnel list with all peer/interface fields intact."
        ),
        ManualStepDefinition(
            id: .pasteAndCreateFromScratch,
            number: 3,
            title: "Paste & Create From Scratch",
            subtitle: "Clipboard import, keypair generation, name validation, natural sort",
            instructions: [
                "Tap 'Copy Sample Config', then 'Open Paste Config' and import it under a test name.",
                "Tap 'Create From Scratch' and verify a private/public keypair is generated and regenerates cleanly.",
                "Test saving with an empty name and with a duplicate name to confirm validation rejects both.",
                "Create or rename tunnels named like 'wg2' and 'wg10' and check natural sort order ('wg2' before 'wg10')."
            ],
            whatToVerify: "Paste and manual creation both work, unique non-empty names are enforced, and list uses natural sort."
        ),
        ManualStepDefinition(
            id: .connectMetricsDisconnect,
            number: 4,
            title: "Connect, Live Metrics & Disconnect",
            subtitle: "Real peer handshake, endpoint, RX/TX counters, and clean stop",
            instructions: [
                "Pick a tunnel with a reachable WireGuard peer below and tap Connect (approve iOS VPN permission if asked).",
                "Confirm status transitions Activating -> Active and open Tunnel Detail to inspect live state.",
                "Generate brief traffic over the tunnel and verify endpoint, RX/TX counters, and last handshake update live.",
                "Tap Disconnect and confirm the tunnel returns cleanly to Inactive."
            ],
            whatToVerify: "Live metrics stream from the extension via ProviderMessage.status and disconnect leaves no stuck state."
        ),
        ManualStepDefinition(
            id: .switchAndEditConnected,
            number: 5,
            title: "Switch Tunnels & Edit Connected",
            subtitle: "Mutual exclusion (A -> B) and live reconnect after editing",
            instructions: [
                "Start Tunnel A so it is Active, then tap Connect on Tunnel B below.",
                "Confirm Tunnel A stops before Tunnel B activates (no stuck Waiting state).",
                "While a tunnel is Active, tap 'Edit Active Tunnel', modify a field (e.g. MTU or DNS), and tap Save.",
                "Confirm the tunnel enters Restarting and automatically reconnects with the updated settings."
            ],
            whatToVerify: "Switching cleanly hands off between tunnels and editing an active tunnel reconnects with the new config."
        ),
        ManualStepDefinition(
            id: .failedStartErrorReporting,
            number: 6,
            title: "Failed Start Error Reporting",
            subtitle: "Extension error alert + fetchLastDisconnectError vs IPC delivery",
            instructions: [
                "Tap 'Create Failing Tunnel' (uses nonexistent-verify-probe.invalid) and tap Activate, OR tap 'Run Probe'.",
                "Confirm SplitGuard displays the extension's specific error reason (DNS resolution failed), not a generic error.",
                "Review the diagnostic readout below confirming whether fetchLastDisconnectError or IPC delivered it.",
                "Tap 'Delete Failing Tunnel' once verified."
            ],
            whatToVerify: "User sees the exact TunnelStartError from PacketTunnelProvider and delivery mechanism is confirmed."
        ),
        ManualStepDefinition(
            id: .splitDNS,
            number: 7,
            title: "Split DNS",
            subtitle: "Only-domains vs all-domains, exclusions, routing preview, live tester",
            instructions: [
                "Edit a tunnel to configure Split DNS in 'Only specific domains' mode with a private domain and an exclusion.",
                "Check that the Routing Preview below matches your domains and exact vs wildcard exclusions.",
                "Connect the tunnel and use the live 'Test a Name' widget below for a matched, excluded, and public hostname.",
                "Switch to 'All domains' mode with an exclusion and verify routing updates accordingly."
            ],
            whatToVerify: "Matched domains resolve via tunnel DNS, excluded and unmatched domains use normal DNS."
        ),
        ManualStepDefinition(
            id: .killSwitch,
            number: 8,
            title: "Kill Switch",
            subtitle: "Strict vs Allow LAN access, and endpoint-cache start while blocked",
            instructions: [
                "Edit a full-tunnel (0.0.0.0/0) profile and enable Kill Switch with Allow Local Network OFF (strict).",
                "Connect and verify LAN hosts are unreachable while VPN traffic works.",
                "Enable Allow Local Network ON, reconnect, and verify local LAN access works while internet stays tunnelled.",
                "With a hostname endpoint + Kill Switch ON: connect once (caches IP), disconnect, and reconnect to verify cache start."
            ],
            whatToVerify: "Strict kill switch blocks LAN, Allow LAN permits LAN, and cached endpoint starts when DNS is blocked."
        ),
        ManualStepDefinition(
            id: .onDemandActivation,
            number: 9,
            title: "On-Demand & iOS 26 Quirks",
            subtitle: "Wi-Fi, cellular, SSID include/exclude lists, and Quirks #2/#3",
            instructions: [
                "Edit a tunnel to enable On-Demand rules: test Wi-Fi, Cellular, and SSID Only/Except (try 'Add connected SSID').",
                "Quirk #2 check: while a tunnel is Active WITHOUT on-demand rules, add on-demand rules and Save.",
                "Quirk #3 check: toggle On-Demand ON/OFF below and verify live connection status updates keep arriving.",
                "Toggle Wi-Fi / Cellular or switch SSIDs to verify iOS auto-connects and auto-disconnects per rule.",
                "Record in Notes whether Quirks #2 and #3 reproduced on iOS 26."
            ],
            whatToVerify: "On-Demand rules persist accurately, auto-trigger as configured, and status updates continue smoothly."
        ),
        ManualStepDefinition(
            id: .deviceAuthAndZipExport,
            number: 10,
            title: "Device Auth & .zip Export",
            subtitle: "Face ID / passcode gates and exported .conf directive preservation",
            instructions: [
                "Tap 'Open Tunnel Detail' below and tap Edit or reveal Private Key — confirm Face ID / Passcode gate appears.",
                "Test cancelling authentication to verify access is blocked cleanly.",
                "Tap 'Export All Tunnels (.zip)' below, authenticate, and save or AirDrop the archive.",
                "Unzip the archive and confirm every .conf is valid WireGuard config and preserves # SplitGuard: comments."
            ],
            whatToVerify: "Both private-key viewing and zip export enforce device auth, and exported .zip unzips cleanly."
        ),
        ManualStepDefinition(
            id: .externalIOSSettingsChanges,
            number: 11,
            title: "External iOS Settings Changes",
            subtitle: "NEVPNConfigurationChange sync from Settings -> VPN",
            instructions: [
                "Note the current tunnel list and Store Revision counter shown below.",
                "Tap 'Open iOS Settings' and go to General -> VPN & Device Management -> VPN.",
                "Toggle a SplitGuard tunnel ON/OFF, toggle Connect On Demand, or delete a disposable test tunnel.",
                "Switch back to SplitGuard and confirm the list, statuses, and revision update automatically."
            ],
            whatToVerify: "External edits and deletions in iOS Settings sync into SplitGuard without restarting the app."
        ),
        ManualStepDefinition(
            id: .homeScreenQuickActions,
            number: 12,
            title: "Home-Screen Quick Actions",
            subtitle: "Long-press app icon shortcuts for recent tunnels",
            instructions: [
                "Ensure at least 1-2 tunnels appear in Recent Tunnels & Registered Shortcuts below.",
                "Return to the iOS Home Screen and long-press the SplitGuard app icon.",
                "Verify recent tunnels appear in the quick action menu.",
                "Tap a shortcut and confirm SplitGuard opens, navigates to that tunnel, and toggles its state."
            ],
            whatToVerify: "Quick actions reflect recent tunnels and launching one navigates to and toggles that tunnel."
        ),
        ManualStepDefinition(
            id: .logViewerAndExport,
            number: 13,
            title: "Log Viewer & Log Export",
            subtitle: "Merged app.log + tunnel.log timeline and plain-text export",
            instructions: [
                "Tap 'Write App Test Line' below (and connect a tunnel briefly if tunnel.log is empty).",
                "Tap 'Open Log Viewer' and verify both [APP] and [NET] lines appear merged in chronological order.",
                "Tap the Export button in Log Viewer and confirm the share sheet produces a readable merged text log."
            ],
            whatToVerify: "MergedLogReader displays interleaved APP and NET entries and exports a clean plain-text file."
        )
    ]

    static func definition(for id: ManualStepID) -> ManualStepDefinition {
        manualSteps.first { $0.id == id } ?? manualSteps[0]
    }
}
#endif
