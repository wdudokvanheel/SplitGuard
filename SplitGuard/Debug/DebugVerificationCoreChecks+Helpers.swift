#if DEBUG
import Foundation
import NetworkExtension
import SplitGuardCore
import WireGuardEngine

extension DebugVerificationCoreChecks {
    static func makeFullSampleProfile(
        name: String,
        endpoint: String = "198.51.100.10:51820",
        killSwitch: TunnelOptions.KillSwitch = .init()
    ) throws -> TunnelProfile {
        let privKey = WireGuardPrivateKey.generate()
        let pubKey = try WireGuardPrivateKey.generate().publicKey()
        guard let ifaceAddr = InterfaceAddress("10.90.0.2/32"),
              let dnsIP = IPAddress("10.90.0.1"),
              let allV4 = InterfaceAddress("0.0.0.0/0")?.network else {
            throw CheckError(message: "Failed to construct sample IP fixtures.")
        }
        let interfaceConfig = InterfaceConfiguration(
            privateKey: privKey,
            addresses: [ifaceAddr],
            listenPort: nil,
            mtu: 1280,
            dnsServers: [dnsIP],
            dnsSearch: []
        )
        let peer = PeerConfiguration(
            publicKey: pubKey,
            presharedKey: nil,
            allowedIPs: [allV4],
            endpoint: Endpoint(endpoint),
            persistentKeepalive: 25
        )
        let splitDNS = SplitDNSConfiguration(
            mode: .onlyDomains,
            domains: [.init(name: "internal.example")],
            exclusions: [.init(name: "skip.internal.example", includesSubdomains: false)]
        )
        return try TunnelProfile(
            name: name,
            interface: interfaceConfig,
            peers: [peer],
            splitDNS: splitDNS,
            options: TunnelOptions(killSwitch: killSwitch)
        )
    }

    static func resolveAndVerifyContainer(
        groupID: String,
        bundle: Bundle,
        fileManager: FileManager,
        notes: inout [String]
    ) throws -> URL {
        if let containerURL = AppGroup.containerURL(in: bundle, fileManager: fileManager) {
            let probeFile = containerURL.appendingPathComponent(".sg-verify-rw-\(UUID().uuidString)")
            let probeData = Data("splitguard-probe".utf8)
            try probeData.write(to: probeFile, options: .atomic)
            defer { try? fileManager.removeItem(at: probeFile) }
            let readBack = try Data(contentsOf: probeFile)
            guard readBack == probeData else {
                throw CheckError(message: "App Group container read-back mismatch.")
            }
            notes.append("Shared container RW verified: \(containerURL.path)")
            appendExistingLogStats(in: containerURL, fileManager: fileManager, notes: &notes)
            return containerURL
        }
        #if targetEnvironment(simulator)
        notes.append("App Group container unavailable on simulator; using temporary directory for LogFile check.")
        return fileManager.temporaryDirectory
        #else
        throw CheckError(message: "AppGroup.containerURL() returned nil for \(groupID).")
        #endif
    }

    static func verifyLogFileRotationAndMerge(
        in baseDir: URL,
        fileManager: FileManager,
        notes: inout [String]
    ) throws {
        let scratchDir = baseDir.appendingPathComponent("sg-verify-logs-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratchDir) }

        let appLog = LogFile(url: AppGroup.appLogURL(inDirectory: scratchDir), maxBytes: 240)
        let tunnelLog = LogFile(url: AppGroup.tunnelLogURL(inDirectory: scratchDir), maxBytes: 1024)
        let baseTime = Date(timeIntervalSince1970: 1_750_000_000)

        for index in 0..<3 {
            appLog.append(
                source: "APP",
                level: .info,
                message: "Verification app message #\(index) padding-for-rotation-check",
                timestamp: baseTime.addingTimeInterval(Double(index * 2))
            )
        }
        tunnelLog.append(
            source: "NET",
            level: .info,
            message: "Verification tunnel interleaved entry",
            timestamp: baseTime.addingTimeInterval(3)
        )
        appLog.flush()
        tunnelLog.flush()

        guard fileManager.fileExists(atPath: appLog.backupURL.path) else {
            throw CheckError(message: "LogFile did not rotate to backup file \(appLog.backupURL.lastPathComponent).")
        }

        let reader = MergedLogReader(directoryURL: scratchDir)
        let merged = reader.readAll()
        guard merged.count == 4 else {
            throw CheckError(message: "MergedLogReader returned \(merged.count) entries instead of 4.")
        }
        for idx in 1..<merged.count where merged[idx].timestamp < merged[idx - 1].timestamp {
            throw CheckError(message: "MergedLogReader output is not chronologically ordered.")
        }
        guard merged.contains(where: { $0.source == "APP" }) && merged.contains(where: { $0.source == "NET" }) else {
            throw CheckError(message: "MergedLogReader did not merge both APP and NET sources.")
        }
        guard reader.exportText().contains("Verification tunnel interleaved entry") else {
            throw CheckError(message: "MergedLogReader.exportText() missing expected entry.")
        }
        notes.append("LogFile rotation (.1 backup) and MergedLogReader chronological merge (4 entries) passed.")
    }

    static func saveSampleWithFallback(
        _ profile: TunnelProfile,
        requestedStore: ProfileStore,
        notes: inout [String]
    ) throws -> (ProfileStore, Data) {
        do {
            let ref = try requestedStore.save(profile)
            notes.append("Saved using accessGroup=\(requestedStore.accessGroup ?? "nil"), service=\(requestedStore.service)")
            return (requestedStore, ref)
        } catch ProfileStoreError.keychainAddFailed(let status) where status == errSecMissingEntitlement {
            #if targetEnvironment(simulator)
            let fallback = ProfileStore(service: "\(requestedStore.service).debug-sim", accessGroup: nil)
            let ref = try fallback.save(profile)
            notes.append("Simulator lacked keychain accessGroup entitlement (-34018); verified with accessGroup=nil.")
            return (fallback, ref)
            #else
            throw ProfileStoreError.keychainAddFailed(status)
            #endif
        }
    }

    static func verifyKeychainRoundTrip(store: ProfileStore, reference: Data, expected: TunnelProfile) throws {
        guard store.verify(reference: reference) else {
            throw CheckError(message: "ProfileStore.verify(reference:) returned false for saved item.")
        }
        let loaded = try store.load(reference: reference, name: expected.name)
        guard loaded == expected else {
            throw CheckError(message: "Round-tripped profile from keychain did not match original.")
        }
    }

    static func deleteAndVerifyKeychainCleanup(store: ProfileStore, references: inout [Data]) throws {
        for ref in references {
            store.delete(reference: ref)
            if store.verify(reference: ref) {
                throw CheckError(message: "Keychain reference still verified as existing after delete.")
            }
        }
        references.removeAll()
    }

    static func verifyProtocolConfiguration(
        using store: ProfileStore,
        profile: TunnelProfile,
        createdRefs: inout [Data]
    ) throws {
        let bundleID = "com.bitechular.splitguard.network-extension"
        let protoAllowLAN = try store.makeProtocol(for: profile, providerBundleIdentifier: bundleID)
        if let ref = protoAllowLAN.passwordReference { createdRefs.append(ref) }
        guard protoAllowLAN.passwordReference != nil,
              protoAllowLAN.providerConfiguration == nil,
              protoAllowLAN.includeAllNetworks == true,
              protoAllowLAN.excludeLocalNetworks == true else {
            throw CheckError(message: "Kill-switch (allow LAN) protocol fields did not match expected values.")
        }

        let strictProfile = try makeFullSampleProfile(
            name: "__SG_VERIFY_KC_STRICT",
            killSwitch: .init(isEnabled: true, allowLocalNetwork: false)
        )
        let protoStrict = try store.makeProtocol(for: strictProfile, providerBundleIdentifier: bundleID)
        if let ref = protoStrict.passwordReference { createdRefs.append(ref) }
        guard protoStrict.providerConfiguration == nil,
              protoStrict.includeAllNetworks == true,
              protoStrict.excludeLocalNetworks == false else {
            throw CheckError(message: "Kill-switch (strict) protocol fields did not match expected values.")
        }

        let offProfile = try makeFullSampleProfile(name: "__SG_VERIFY_KC_OFF")
        let protoOff = try store.makeProtocol(for: offProfile, providerBundleIdentifier: bundleID)
        if let ref = protoOff.passwordReference { createdRefs.append(ref) }
        guard protoOff.providerConfiguration == nil,
              protoOff.includeAllNetworks == false,
              protoOff.excludeLocalNetworks == false else {
            throw CheckError(message: "Kill-switch (off) protocol fields did not match expected values.")
        }
    }

    static func verifyCodecRoundTrip() throws -> TunnelProfile {
        let privateKey = WireGuardPrivateKey.generate()
        let peer1Key = try WireGuardPrivateKey.generate().publicKey()
        let peer2Key = try WireGuardPrivateKey.generate().publicKey()
        guard let psk = WireGuardPresharedKey(rawValue: Data(repeating: 0x42, count: 32)) else {
            throw CheckError(message: "Failed to build preshared key fixture.")
        }

        let rawConfig = """
        # SplitGuard: split-dns-mode = only-domains
        # SplitGuard: split-dns-domains = corp.internal, lab.local
        # SplitGuard: split-dns-exclude = public.corp.internal
        # SplitGuard: split-dns-exclude-exact = corp.internal
        # SplitGuard: kill-switch = on
        # SplitGuard: kill-switch-allow-lan = on
        [Interface]
        PrivateKey = \(privateKey.base64)
        Address = 10.77.0.2/32, fd00:77::2/128
        ListenPort = 51821
        DNS = 10.77.0.1, 2001:4860:4860::8888, corp.internal
        MTU = 1380

        [Peer]
        PublicKey = \(peer1Key.base64)
        PresharedKey = \(psk.base64)
        Endpoint = vpn.example.com:51820
        AllowedIPs = 0.0.0.0/0, 192.168.1.42/24
        PersistentKeepalive = 25

        [Peer]
        PublicKey = \(peer2Key.base64)
        Endpoint = [2001:db8::1]:51820
        AllowedIPs = ::/0
        """

        let parsed = try TunnelProfileCodec.parse(rawConfig, name: "CodecProbe")
        let reparsed = try TunnelProfileCodec.parse(TunnelProfileCodec.serialize(parsed), name: "CodecProbe")
        guard parsed == reparsed,
              parsed.peers.count == 2,
              parsed.peers[0].allowedIPs.map(\.description).contains("192.168.1.0/24"),
              parsed.peers[1].endpoint?.description == "[2001:db8::1]:51820",
              parsed.splitDNS.mode == .onlyDomains,
              parsed.splitDNS.normalizedDomainNames == ["corp.internal", "lab.local"],
              parsed.splitDNS.exclusions.count == 2,
              parsed.options.killSwitch == .init(isEnabled: true, allowLocalNetwork: true) else {
            throw CheckError(message: "Codec round-trip or parsed fields did not match expected values.")
        }
        return parsed
    }

    static func parseAndVerifyBundledFixtures() throws -> [TunnelProfile] {
        var parsed: [TunnelProfile] = []
        for fixture in DebugBundledFixtures.allAvailable() {
            let profile = try DebugBundledFixtures.parsedProfile(for: fixture)
            let reparsed = try TunnelProfileCodec.parse(TunnelProfileCodec.serialize(profile), name: profile.name)
            guard profile == reparsed else {
                throw CheckError(message: "Bundled fixture \(fixture.fileName) failed serialize/parse round-trip.")
            }
            parsed.append(profile)
        }
        return parsed
    }

    static func verifyZipArchiveExport(
        primaryProfile: TunnelProfile,
        extraProfiles: [TunnelProfile] = [],
        fileManager: FileManager
    ) throws -> Int {
        let tempZipURL = fileManager.temporaryDirectory
            .appendingPathComponent("SplitGuardVerify-\(UUID().uuidString).zip")
        defer { try? fileManager.removeItem(at: tempZipURL) }

        let secondProfile = try makeFullSampleProfile(name: "SecondProbe")
        let allProfiles = [primaryProfile, secondProfile] + extraProfiles
        try ProfileArchiveExporter.export(profiles: allProfiles, to: tempZipURL)

        let zipData = try Data(contentsOf: tempZipURL)
        guard zipData.count >= 4,
              zipData[0] == 0x50, zipData[1] == 0x4B, zipData[2] == 0x03, zipData[3] == 0x04 else {
            throw CheckError(message: "Exported zip archive is missing PK\\x03\\x04 header.")
        }
        let latinText = String(data: zipData, encoding: .isoLatin1) ?? ""
        guard latinText.contains("CodecProbe.conf") && latinText.contains("SecondProbe.conf") else {
            throw CheckError(message: "Exported zip archive does not list expected .conf filenames.")
        }

        let leakedDirs = (try? fileManager.contentsOfDirectory(atPath: fileManager.temporaryDirectory.path))?
            .filter { $0.hasPrefix("SplitGuardExport-") } ?? []
        guard leakedDirs.isEmpty else {
            throw CheckError(message: "ProfileArchiveExporter leaked temp directories: \(leakedDirs.joined(separator: ", "))")
        }
        return zipData.count
    }

    static func verifyOnDemandPolicyRoundTrips() throws -> Int {
        let policies: [OnDemandPolicy] = [
            .off,
            OnDemandPolicy(cellular: false, wifi: true, ssidFilter: .any),
            OnDemandPolicy(cellular: true, wifi: false, ssidFilter: .any),
            OnDemandPolicy(cellular: true, wifi: true, ssidFilter: .any),
            OnDemandPolicy(cellular: false, wifi: true, ssidFilter: .only(["OfficeWiFi", "Lab5G"])),
            OnDemandPolicy(cellular: true, wifi: true, ssidFilter: .only(["OfficeWiFi"])),
            OnDemandPolicy(cellular: false, wifi: true, ssidFilter: .except(["HomeNet"])),
            OnDemandPolicy(cellular: true, wifi: true, ssidFilter: .except(["HomeNet", "Trusted"]))
        ]
        for policy in policies {
            let roundTripped = OnDemandPolicy(from: policy.makeRules())
            guard roundTripped == policy.normalized() else {
                throw CheckError(message: "OnDemandPolicy round-trip failed for \(policy).")
            }
        }
        return policies.count
    }

    static func verifyAllowedIPHelpers() throws {
        let excluded = AllowedIPHelpers.applyingExcludePrivateIPs(true, to: "0.0.0.0/0, ::/0", dnsText: "10.0.0.1")
        guard AllowedIPHelpers.isExcludingPrivateIPs(allowedIPs: excluded),
              excluded.contains("10.0.0.1/32"),
              AllowedIPHelpers.canToggleExcludePrivateIPs(peerAllowedIPs: excluded, peerCount: 1) else {
            throw CheckError(message: "AllowedIPHelpers RFC1918 exclusion failed.")
        }
        let restored = AllowedIPHelpers.applyingExcludePrivateIPs(false, to: excluded, dnsText: "10.0.0.1")
        guard !AllowedIPHelpers.isExcludingPrivateIPs(allowedIPs: restored),
              restored.contains("0.0.0.0/0") else {
            throw CheckError(message: "AllowedIPHelpers restore 0.0.0.0/0 failed.")
        }
    }

    static func verifyDraftValidation() throws {
        let privKey = WireGuardPrivateKey.generate()
        let expectedPub = try privKey.publicKey().base64
        let peerPub = try WireGuardPrivateKey.generate().publicKey().base64

        let validDraft = TunnelDraft(
            interface: InterfaceDraft(
                name: "DraftProbe", privateKey: privKey.base64, addresses: "10.0.0.2/32",
                listenPort: "51820", mtu: "1420", dns: "1.1.1.1"
            ),
            peers: [PeerDraft(publicKey: peerPub, endpoint: "198.51.100.5:51820", allowedIPs: "0.0.0.0/0", persistentKeepalive: "25")]
        )
        guard validDraft.interface.derivedPublicKey == expectedPub,
              case .success(let builtProfile) = validDraft.validate(),
              builtProfile.name == "DraftProbe", builtProfile.peers.count == 1 else {
            throw CheckError(message: "Valid TunnelDraft failed validation or public key derivation.")
        }

        var invalidDraft = validDraft
        invalidDraft.interface.name = "   "
        invalidDraft.interface.mtu = "200"
        guard case .failure(let ifaceErr) = invalidDraft.validate(),
              ifaceErr.interfaceFields.contains(.name), ifaceErr.interfaceFields.contains(.mtu) else {
            throw CheckError(message: "Invalid interface draft did not flag .name and .mtu.")
        }

        var badEndpointDraft = validDraft
        badEndpointDraft.peers[0].endpoint = "bad-endpoint"
        guard case .failure(let endpointErr) = badEndpointDraft.validate(),
              let firstID = badEndpointDraft.peers.first?.id,
              endpointErr.peerFieldsByID[firstID]?.contains(.endpoint) == true else {
            throw CheckError(message: "Invalid peer endpoint draft did not flag .endpoint.")
        }

        var dupPeerDraft = validDraft
        dupPeerDraft.peers.append(PeerDraft(publicKey: peerPub, endpoint: "198.51.100.6:51820", allowedIPs: "10.0.0.0/24"))
        guard case .failure(let dupErr) = dupPeerDraft.validate(),
              let secondID = dupPeerDraft.peers.last?.id,
              dupErr.peerFieldsByID[secondID]?.contains(.publicKey) == true else {
            throw CheckError(message: "Duplicate peer public key draft did not flag .publicKey.")
        }
    }

    static func appendExistingLogStats(in containerURL: URL, fileManager: FileManager, notes: inout [String]) {
        for url in AppGroup.logFileURLs(inDirectory: containerURL) {
            if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                notes.append("Live \(url.lastPathComponent): \(size.intValue) bytes")
            } else {
                notes.append("Live \(url.lastPathComponent): not created yet")
            }
        }
    }
}
#endif
