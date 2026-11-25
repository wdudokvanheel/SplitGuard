#if DEBUG && targetEnvironment(simulator)
import Foundation
import SplitGuardCore
import WireGuardEngine

/// Seeds the simulator's in-memory backend with realistic tunnels for App Store screenshots.
/// Enabled by launching with `-SGScreenshotDemo`.
enum ScreenshotDemoData {
    static let launchFlag = "-SGScreenshotDemo"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchFlag)
    }

    static func makeBackend() -> InMemoryTunnelBackend {
        var records: [TunnelRecord] = []
        var statuses: [UUID: DeviceStatus] = [:]

        for seed in seeds {
            guard let profile = try? TunnelProfileCodec.parse(seed.config(), name: seed.name) else {
                Log.error("Screenshot demo tunnel \(seed.name) failed to parse")
                continue
            }
            records.append(TunnelRecord(
                id: seed.id,
                profile: profile,
                status: seed.isActive ? .active : .inactive,
                onDemandPolicy: seed.onDemand,
                isOnDemandEnabled: seed.isActive && seed.onDemand.hasRules,
                localSettings: seed.localSettings
            ))
            if seed.isActive {
                statuses[seed.id] = activeStatus(for: profile)
            }
        }

        return InMemoryTunnelBackend(initialRecords: records, initialDeviceStatuses: statuses)
    }

    static func lookupResult(for hostname: String) -> DNSLookupResult? {
        guard isRequested else { return nil }
        let address = demoAddresses[hostname.lowercased()] ?? "192.168.1.20"
        return DNSLookupResult(hostname: hostname, addresses: [address], durationMilliseconds: 14, errorMessage: nil)
    }

    private static let demoAddresses: [String: String] = [
        "plex.home.arpa": "192.168.1.20",
        "nas.lan": "192.168.1.10",
        "grafana.northwind.internal": "10.20.4.18"
    ]

    private static func activeStatus(for profile: TunnelProfile) -> DeviceStatus {
        let now = Date()
        let peers = profile.peers.map { peer in
            PeerStatus(
                publicKey: peer.publicKey,
                endpoint: IPEndpoint("84.27.143.96:51820"),
                health: .healthy,
                lastHandshake: now.addingTimeInterval(-38),
                handshakeRoundTrip: .milliseconds(24),
                handshakeAttempts: 1,
                rxBytes: 1_947_302_118,
                txBytes: 214_880_432,
                lastReceived: now.addingTimeInterval(-1),
                lastSent: now.addingTimeInterval(-1)
            )
        }
        return DeviceStatus(state: .up, listenPort: 51820, peers: peers)
    }

    private struct Seed {
        let id: UUID
        let name: String
        let isActive: Bool
        let onDemand: OnDemandPolicy
        let localSettings: TunnelLocalSettings
        let directives: [String]
        let address: String
        let dns: String
        let allowedIPs: String
        let endpoint: String
        let keepalive: Int?

        func config() -> String {
            let privateKey = WireGuardPrivateKey.generate().base64
            let peerKey = (try? WireGuardPrivateKey.generate().publicKey().base64) ?? ""
            var lines = directives.map { "# SplitGuard: \($0)" }
            lines += [
                "[Interface]",
                "PrivateKey = \(privateKey)",
                "Address = \(address)",
                "DNS = \(dns)",
                "",
                "[Peer]",
                "PublicKey = \(peerKey)",
                "AllowedIPs = \(allowedIPs)",
                "Endpoint = \(endpoint)"
            ]
            if let keepalive {
                lines.append("PersistentKeepalive = \(keepalive)")
            }
            return lines.joined(separator: "\n")
        }
    }

    private static let seeds: [Seed] = [
        Seed(
            id: UUID(uuidString: "5D1C7A4E-2B61-4C0F-9E1A-0A11C0DE0001")!,
            name: "Home",
            isActive: true,
            onDemand: OnDemandPolicy(cellular: true, wifi: true, ssidFilter: .except(["Maple Court"])),
            localSettings: TunnelLocalSettings(healthAlerts: .init(isEnabled: true, delaySeconds: 60)),
            directives: [
                "split-dns-mode = only-domains",
                "split-dns-domains = home.arpa, nas.lan, pihole.lan"
            ],
            address: "10.6.0.2/32, fd86:ea04:1115::2/128",
            dns: "10.6.0.1",
            allowedIPs: "10.6.0.0/24, 192.168.1.0/24",
            endpoint: "home.maplecourt.net:51820",
            keepalive: 25
        ),
        Seed(
            id: UUID(uuidString: "5D1C7A4E-2B61-4C0F-9E1A-0A11C0DE0002")!,
            name: "Northwind Office",
            isActive: false,
            onDemand: .off,
            localSettings: .default,
            directives: [
                "split-dns-mode = only-domains",
                "split-dns-domains = northwind.internal, corp.northwind.io, svc.cluster.local",
                "split-dns-exclude-exact = www.northwind.io"
            ],
            address: "10.20.14.37/32",
            dns: "10.20.0.53, 10.20.0.54",
            allowedIPs: "10.20.0.0/16, 172.16.0.0/12",
            endpoint: "gw.northwind.io:51820",
            keepalive: nil
        ),
        Seed(
            id: UUID(uuidString: "5D1C7A4E-2B61-4C0F-9E1A-0A11C0DE0003")!,
            name: "Amsterdam Exit",
            isActive: false,
            onDemand: OnDemandPolicy(cellular: false, wifi: true, ssidFilter: .except(["Maple Court", "Northwind Staff"])),
            localSettings: TunnelLocalSettings(healthAlerts: .init(isEnabled: true, delaySeconds: 120)),
            directives: [
                "kill-switch = on",
                "kill-switch-allow-lan = on"
            ],
            address: "10.64.112.9/32, fc00:bbbb:bbbb:bb01::1:7008/128",
            dns: "10.64.0.1",
            allowedIPs: "0.0.0.0/0, ::/0",
            endpoint: "ams1.relaywave.net:51820",
            keepalive: nil
        ),
        Seed(
            id: UUID(uuidString: "5D1C7A4E-2B61-4C0F-9E1A-0A11C0DE0004")!,
            name: "Staging Cluster",
            isActive: false,
            onDemand: .off,
            localSettings: .default,
            directives: [
                "split-dns-mode = only-domains",
                "split-dns-domains = staging.northwind.io, k8s.internal"
            ],
            address: "10.42.8.21/32",
            dns: "10.42.0.10",
            allowedIPs: "10.42.0.0/16",
            endpoint: "bastion.staging.northwind.io:51820",
            keepalive: 25
        ),
        Seed(
            id: UUID(uuidString: "5D1C7A4E-2B61-4C0F-9E1A-0A11C0DE0005")!,
            name: "Parents' House",
            isActive: false,
            onDemand: .off,
            localSettings: .default,
            directives: [],
            address: "192.168.178.240/32",
            dns: "192.168.178.1",
            allowedIPs: "192.168.178.0/24",
            endpoint: "vpn.oakridge-family.net:51820",
            keepalive: 25
        )
    ]
}
#endif
