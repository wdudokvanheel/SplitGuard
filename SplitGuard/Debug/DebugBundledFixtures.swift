#if DEBUG
import CoreImage.CIFilterBuiltins
import Foundation
import SplitGuardCore
import UIKit

struct DebugBundledFixture: Identifiable, Equatable, Sendable {
    let id: String
    let fileName: String
    let displayName: String
    let roleSummary: String
    let rawText: String
    let bundleURL: URL
}

enum DebugBundledFixtures {
    static let subdirectory = "DebugFixtures"
    static let serverTestBaseName = "ServerTest"
    static let testCertBaseName = "TestCert"

    static func serverTest(in bundle: Bundle = .main) -> DebugBundledFixture? {
        loadFixture(resourceName: serverTestBaseName, displayName: "ServerTest", bundle: bundle)
    }

    static func testCert(in bundle: Bundle = .main) -> DebugBundledFixture? {
        loadFixture(resourceName: testCertBaseName, displayName: "TestCert", bundle: bundle)
    }

    static func allAvailable(in bundle: Bundle = .main) -> [DebugBundledFixture] {
        [serverTest(in: bundle), testCert(in: bundle)].compactMap { $0 }
    }

    static func parsedProfile(
        for fixture: DebugBundledFixture,
        named overrideName: String? = nil
    ) throws -> TunnelProfile {
        try TunnelProfileCodec.parse(fixture.rawText, name: overrideName ?? fixture.displayName)
    }

    static func writeTempConfFile(for fixture: DebugBundledFixture) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fixture.fileName)
        do {
            try Data(fixture.rawText.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func qrCodeImage(for text: String, scale: CGFloat = 8) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func writeQRCodePNG(for fixture: DebugBundledFixture) -> URL? {
        guard let image = qrCodeImage(for: fixture.rawText, scale: 12),
              let pngData = image.pngData() else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fixture.displayName)-QR.png")
        do {
            try pngData.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    @MainActor
    @discardableResult
    static func ensureLoaded(
        fixture: DebugBundledFixture,
        named name: String,
        splitDNS: SplitDNSConfiguration? = nil,
        killSwitch: TunnelOptions.KillSwitch? = nil,
        in store: TunnelStore
    ) async throws -> Tunnel {
        if let existing = store.tunnel(named: name) {
            return existing
        }
        var profile = try parsedProfile(for: fixture, named: name)
        if let splitDNS {
            profile.splitDNS = splitDNS
        }
        if let killSwitch {
            profile.options = TunnelOptions(killSwitch: killSwitch).sanitized(for: profile)
        }
        return try await store.addTunnel(profile, onDemandPolicy: .off)
    }

    private static func loadFixture(
        resourceName: String,
        displayName: String,
        bundle: Bundle
    ) -> DebugBundledFixture? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "conf", subdirectory: subdirectory),
              let rawText = try? String(contentsOf: url, encoding: .utf8),
              !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let roleSummary = describeFixture(rawText: rawText, name: displayName)
        return DebugBundledFixture(
            id: resourceName,
            fileName: "\(resourceName).conf",
            displayName: displayName,
            roleSummary: roleSummary,
            rawText: rawText,
            bundleURL: url
        )
    }

    private static func describeFixture(rawText: String, name: String) -> String {
        guard let profile = try? TunnelProfileCodec.parse(rawText, name: name) else {
            return "Bundled .conf fixture"
        }
        let mode = profile.routesAllIPv4Traffic ? "Full tunnel" : "Split tunnel"
        let endpoint = profile.peers.first?.endpoint?.description ?? "no endpoint"
        let dns = profile.interface.dnsServers.map(\.description).joined(separator: ", ")
        return dns.isEmpty ? "\(mode) • \(endpoint)" : "\(mode) • \(endpoint) • DNS \(dns)"
    }
}
#endif
