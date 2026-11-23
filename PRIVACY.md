# Privacy policy

Last updated: November 24, 2026

SplitGuard is an iPhone client for WireGuard VPN tunnels published by Bitechular Innovations B.V.

## Data collection

SplitGuard does not collect personal data, usage data, analytics, diagnostics, or browsing activity. The app has no user accounts, no advertising, no tracking, and no third-party analytics or crash-reporting SDKs.

## VPN traffic

SplitGuard has no backend servers. When you activate a tunnel, your iPhone connects directly to the WireGuard server you configured. DNS lookups go either to the tunnel's DNS server or to your current network's DNS server, depending on your split DNS settings. Bitechular Innovations B.V. does not receive, inspect, or log your network traffic, DNS queries, IP addresses, or tunnel configurations.

## Data stored on your device

All configuration data stays on your iPhone:

- Tunnel configurations and split DNS settings are stored locally in iOS VPN preferences and the app's private container.
- WireGuard private keys are stored in the iOS Keychain.
- Tunnel and network extension logs are kept in a local log buffer on your device and are only exported if you tap the export button.
- App preferences (appearance mode, pinned tunnel, and recently used tunnels) are stored locally on your device.

Deleting a tunnel removes its configuration and private key from your device. Exporting tunnels as a `.zip` archive or exporting logs happens only when you initiate it and share the file yourself. Uninstalling SplitGuard removes its local data and logs.

## Device permissions

- VPN configuration permission is required by iOS to create and run WireGuard packet tunnels on your device.
- Camera access is used only to scan WireGuard configuration QR codes. Camera frames are processed on your device and are not saved or transmitted.
- Face ID or your device passcode is used to gate viewing private keys and exporting tunnel archives. Authentication is handled by iOS, and SplitGuard does not have access to biometric data.
- Wi-Fi network access is used only when you choose to add your current Wi-Fi network name (SSID) to a tunnel's on-demand activation rules. Saved network names stay on your device.

## Third-party VPN servers

SplitGuard connects only to the WireGuard servers and DNS servers you configure. Those servers are operated by you or by the provider you choose, and any data sent to them is governed by that operator's policies.

## Changes

If this privacy policy changes, the updated version will be published in this repository with a new date at the top of the page.

## Contact

If you have questions about this privacy policy, email wesley@bitechular.com or open an issue at https://github.com/wdudokvanheel/SplitGuard.
