#if DEBUG
import Foundation

enum DebugVerificationCatalog {
    static let manualSteps: [ManualStepDefinition] = [
        ManualStepDefinition(
            id: .importFilesAndAirDrop,
            number: 1,
            title: "Files & Open-In Import",
            subtitle: "System document picker & AirDrop using supplied ServerTest / TestCert configs",
            instructions: [
                "Tap 'Share ServerTest.conf' or 'Share TestCert.conf' below and save to Files (or AirDrop from Mac).",
                "Tap 'Pick .conf File(s)' and select one or both saved .conf files (tests multi-select).",
                "Confirm the tunnel(s) import with filename as name and Split DNS suggestion prompts when applicable."
            ],
            whatToVerify: "iOS Files picker and Open-In import bundled .conf files cleanly with zero crashes."
        ),
        ManualStepDefinition(
            id: .importQRCode,
            number: 2,
            title: "QR Code Camera Scanner",
            subtitle: "Camera permission & scan using supplied QR code image",
            instructions: [
                "Tap 'Share QR Image' below to send the ServerTest or TestCert QR code to your Mac / another screen.",
                "Tap 'Open QR Scanner', grant camera access if prompted, and scan the QR code.",
                "Enter a tunnel name when prompted and confirm it saves into SplitGuard."
            ],
            whatToVerify: "Camera scanner decodes the WireGuard QR code and imports the profile cleanly."
        ),
        ManualStepDefinition(
            id: .physicalSplitDNSAndKillSwitch,
            number: 3,
            title: "Private DNS & LAN Kill Switch",
            subtitle: "Optional physical-network spot check using supplied TestCert & ServerTest",
            instructions: [
                "Tap 'Load TestCert (Split DNS)' below, connect it, and use 'Test a Name' to resolve a private hw45.nl host on 10.0.0.10.",
                "Tap 'Load ServerTest (Strict Kill Switch)', connect it, and confirm a local LAN IP is blocked while internet works.",
                "Switch Allow Local Network ON in the editor and confirm local LAN access returns while internet stays tunnelled."
            ],
            whatToVerify: "Internal DNS host resolves via 10.0.0.10, strict Kill Switch blocks LAN, and Allow LAN restores LAN access."
        ),
        ManualStepDefinition(
            id: .onDemandNetworkSwitch,
            number: 4,
            title: "On-Demand Wi-Fi / Cellular / SSID",
            subtitle: "Physical radio switching & connected-SSID entitlement",
            instructions: [
                "Tap 'Load ServerTest for On-Demand' below, then tap 'Edit Rules' to configure Wi-Fi / Cellular / SSID rules.",
                "Tap 'Add connected SSID' inside the SSID editor to confirm the Wi-Fi info entitlement reads your SSID.",
                "Enable On-Demand, toggle Wi-Fi or Cellular in Control Center, and confirm iOS auto-connects / disconnects per rule."
            ],
            whatToVerify: "Connected SSID detection works and iOS triggers automatic VPN connect/disconnect on radio changes."
        ),
        ManualStepDefinition(
            id: .deviceAuthAndZipExport,
            number: 5,
            title: "Face ID Gate & .zip Export",
            subtitle: "Biometric/passcode protection for private keys and archive export",
            instructions: [
                "Tap 'Ensure Bundled Tunnels Loaded' if you have no tunnels yet.",
                "Tap 'Open Detail' and tap Edit / Private Key — confirm Face ID / Passcode gate triggers and blocks on Cancel.",
                "Tap 'Export All Tunnels (.zip)', authenticate, save or AirDrop the archive, and verify it unzips cleanly."
            ],
            whatToVerify: "Private key access & zip export enforce device auth, and .conf files preserve # SplitGuard: comments."
        ),
        ManualStepDefinition(
            id: .externalIOSSettingsChanges,
            number: 6,
            title: "External iOS Settings Sync",
            subtitle: "NEVPNConfigurationChange sync from Settings -> VPN",
            instructions: [
                "Tap 'Create Disposable TestCert Tunnel' below and note the Store Revision number.",
                "Tap 'Open iOS Settings' -> General -> VPN & Device Management -> VPN.",
                "Toggle Connect On Demand or delete the disposable tunnel in iOS Settings, then return to SplitGuard."
            ],
            whatToVerify: "SplitGuard automatically reflects the Settings change and increments Store Revision without restarting."
        ),
        ManualStepDefinition(
            id: .quickActionsAndLogViewer,
            number: 7,
            title: "Quick Actions & Log Viewer UI",
            subtitle: "Home-screen icon long-press shortcuts and merged log viewer share sheet",
            instructions: [
                "Confirm recent tunnels appear below (automated live tests populate them, or tap 'Refresh Quick Actions').",
                "Go to the iOS Home Screen, long-press the SplitGuard icon, and tap a recent tunnel shortcut.",
                "Return here, tap 'Open Log Viewer', confirm merged [APP] + [NET] lines render cleanly, and test Log Export."
            ],
            whatToVerify: "Home-screen quick actions navigate & toggle the tunnel, and Log Viewer displays & exports merged logs."
        )
    ]

    static func definition(for id: ManualStepID) -> ManualStepDefinition {
        manualSteps.first { $0.id == id } ?? manualSteps[0]
    }
}
#endif
