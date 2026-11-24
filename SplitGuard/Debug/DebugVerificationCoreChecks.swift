#if DEBUG
import Foundation
import NetworkExtension
import SplitGuardCore
import WireGuardEngine

enum DebugVerificationCoreChecks {
    struct CheckError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct CheckPayload {
        let status: AutomatedCheckStatus
        let summary: String
        let detail: String
    }

    static func reviewRegression(_ id: AutomatedCheckID) -> AutomatedCheckResult {
        measure(id) {
            let failures: [String]
            switch id {
            case .zeroKeyBoundary, .mtuBoundary:
                let profile = try makeFullSampleProfile(name: "BoundaryFixture")
                let text = TunnelProfileCodec.serialize(profile)
                var draft = TunnelDraft(profile: profile)
                if id == .zeroKeyBoundary {
                    let zero = Data(repeating: 0, count: 32).base64EncodedString()
                    draft.interface.privateKey = zero
                    let invalid = text.replacingOccurrences(of: profile.interface.privateKey.base64, with: zero)
                    failures = inputMismatches(draft, invalid, expectingValid: false)
                } else {
                    var results: [String] = []
                    for mtu in [WireGuardDevice.maxContentSize, WireGuardDevice.maxContentSize + 1] {
                        draft.interface.mtu = String(mtu)
                        let config = text.replacingOccurrences(of: "MTU = 1280", with: "MTU = \(mtu)")
                        results += inputMismatches(draft, config, expectingValid: mtu == WireGuardDevice.maxContentSize)
                            .map { "MTU \(mtu) \($0)" }
                    }
                    failures = results
                }
            case .liveVerdictFixtures:
                failures = DebugVerificationLiveChecks.verdictMismatches()
            default:
                throw CheckError(message: "Unknown regression fixture")
            }
            return CheckPayload(status: failures.isEmpty ? .passed : .failed,
                                summary: failures.isEmpty ? "Fixture expectations met" : failures.joined(separator: ", "),
                                detail: failures.joined(separator: "\n"))
        }
    }

    private static func inputMismatches(_ draft: TunnelDraft, _ text: String, expectingValid: Bool) -> [String] {
        let imported = (try? TunnelProfileCodec.parse(text)) != nil
        let edited = (try? draft.validate().get()) != nil
        var failures = [String]()
        if imported != expectingValid { failures.append("import accepted=\(imported)") }
        if edited != expectingValid { failures.append("editor accepted=\(edited)") }
        return failures
    }

    static func runAppGroupAndLoggingCheck(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> AutomatedCheckResult {
        measure(.appGroupLogging) {
            var notes: [String] = []
            guard let groupID = AppGroup.identifier(in: bundle) else {
                throw CheckError(message: "AppGroup.identifier() returned nil for key \(AppGroup.infoDictionaryKey).")
            }
            notes.append("SplitGuardAppGroupID = \(groupID)")

            let baseDir = try resolveAndVerifyContainer(
                groupID: groupID,
                bundle: bundle,
                fileManager: fileManager,
                notes: &notes
            )
            try verifyLogFileRotationAndMerge(in: baseDir, fileManager: fileManager, notes: &notes)
            return CheckPayload(
                status: .passed,
                summary: "App Group, LogFile rotation & MergedLogReader verified",
                detail: notes.joined(separator: "\n")
            )
        }
    }

    static func runKeychainAndProfileStoreCheck(
        profileStore: ProfileStore? = nil
    ) -> AutomatedCheckResult {
        measure(.keychainProfileStore) {
            let requestedStore = profileStore ?? ProfileStore()
            var createdRefs: [Data] = []
            let sampleProfile = try makeFullSampleProfile(
                name: "__SG_VERIFY_KC",
                killSwitch: TunnelOptions.KillSwitch(isEnabled: true, allowLocalNetwork: true)
            )
            var notes: [String] = []
            let (activeStore, savedRef) = try saveSampleWithFallback(
                sampleProfile,
                requestedStore: requestedStore,
                notes: &notes
            )
            createdRefs.append(savedRef)
            defer {
                for ref in createdRefs { activeStore.delete(reference: ref) }
            }

            try verifyKeychainRoundTrip(store: activeStore, reference: savedRef, expected: sampleProfile)
            try verifyProtocolConfiguration(using: activeStore, profile: sampleProfile, createdRefs: &createdRefs)
            notes.append("NETunnelProviderProtocol verified: passwordReference set, providerConfiguration == nil, kill-switch flags match.")
            try deleteAndVerifyKeychainCleanup(store: activeStore, references: &createdRefs)
            notes.append("Cleanup verified: all temporary keychain items deleted.")

            return CheckPayload(
                status: .passed,
                summary: "Keychain CRUD & protocol flags verified",
                detail: notes.joined(separator: "\n")
            )
        }
    }

    static func runCodecAndZipExportCheck(fileManager: FileManager = .default) -> AutomatedCheckResult {
        measure(.codecAndZipExport) {
            let parsed = try verifyCodecRoundTrip()
            let bundledProfiles = try parseAndVerifyBundledFixtures()
            let zipByteCount = try verifyZipArchiveExport(
                primaryProfile: parsed,
                extraProfiles: bundledProfiles,
                fileManager: fileManager
            )
            var details = [
                "Codec round-trip passed (IPv4/IPv6, hostnames, host-bit masking, # SplitGuard: directives).",
                "PKZIP verified (\(zipByteCount) bytes) with temp staging cleanup (0 leaked dirs)."
            ]
            if bundledProfiles.isEmpty {
                details.append("Bundled docs/*.conf fixtures: none bundled in this build.")
            } else {
                let names = bundledProfiles.map(\.name).joined(separator: ", ")
                details.append("Bundled fixtures parsed & exported cleanly: \(names).")
            }
            return CheckPayload(
                status: .passed,
                summary: "Codec, fixtures (\(bundledProfiles.count)) & PKZIP verified (\(zipByteCount) B)",
                detail: details.joined(separator: "\n")
            )
        }
    }

    static func runOnDemandAndDraftValidationCheck() -> AutomatedCheckResult {
        measure(.onDemandAndDraftValidation) {
            let policyCount = try verifyOnDemandPolicyRoundTrips()
            try verifyAllowedIPHelpers()
            try verifyDraftValidation()

            let details = [
                "OnDemandPolicy: \(policyCount) rule combinations round-tripped cleanly.",
                "AllowedIPHelpers: RFC1918 exclusion + DNS pinning + restore passed.",
                "TunnelDraft: valid build, derivedPublicKey, and invalid field checks passed."
            ].joined(separator: "\n")
            return CheckPayload(
                status: .passed,
                summary: "OnDemandPolicy, RFC1918 helper & TunnelDraft verified",
                detail: details
            )
        }
    }

    @MainActor
    static func runImportPasteCreateAndSortCheck(fileManager: FileManager = .default) async -> AutomatedCheckResult {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let notes = try await executeImportPasteCreateCheck(fileManager: fileManager)
            return AutomatedCheckResult(
                id: .importPasteCreateAndSort,
                status: .passed,
                summary: "File import, paste, create-from-scratch, name validation & sort verified",
                detail: notes.joined(separator: "\n"),
                durationMilliseconds: durationMs(since: start, clock: clock)
            )
        } catch {
            return AutomatedCheckResult(
                id: .importPasteCreateAndSort,
                status: .failed,
                summary: error.localizedDescription,
                detail: String(describing: error),
                durationMilliseconds: durationMs(since: start, clock: clock)
            )
        }
    }

    @MainActor
    private static func executeImportPasteCreateCheck(fileManager: FileManager) async throws -> [String] {
        let scratchDir = fileManager.temporaryDirectory.appendingPathComponent("sg-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratchDir) }

        let invalidURL = scratchDir.appendingPathComponent("broken.conf")
        try Data("not a valid wireguard config".utf8).write(to: invalidURL)
        let bundled = DebugBundledFixtures.allAvailable()
        var validURLs = bundled.map(\.bundleURL)
        if validURLs.isEmpty {
            let fallbackURL = scratchDir.appendingPathComponent("fallback.conf")
            let fallbackText = TunnelProfileCodec.serialize(try makeFullSampleProfile(name: "fallback"))
            try Data(fallbackText.utf8).write(to: fallbackURL)
            validURLs = [fallbackURL]
        }

        let outcome = await TunnelImportService.importFiles(from: validURLs + [invalidURL])
        guard outcome.profiles.count == validURLs.count, outcome.failures.count == 1 else {
            throw CheckError(message: "TunnelImportService returned \(outcome.profiles.count) ok / \(outcome.failures.count) failed.")
        }

        let pasteText: String
        if let firstBundled = bundled.first {
            pasteText = firstBundled.rawText
        } else {
            pasteText = TunnelProfileCodec.serialize(try makeFullSampleProfile(name: "wg10"))
        }
        try await verifyPasteCreateAndNaturalSort(pasteText: pasteText)
        return [
            "TunnelImportService parsed \(outcome.profiles.count) valid .conf file(s) and rejected 1 invalid file.",
            "Paste import, natural sort (wg2 < wg10), keypair regeneration & duplicate/empty name guards passed."
        ]
    }

    @MainActor
    private static func verifyPasteCreateAndNaturalSort(pasteText: String) async throws {
        let scratchStore = TunnelStore(backend: InMemoryTunnelBackend(), autoLoad: false)
        await scratchStore.loadTunnels()
        guard await scratchStore.importConfigText(pasteText, named: "wg10"),
              await scratchStore.importConfigText(pasteText, named: "wg2") else {
            throw CheckError(message: "Paste import (importConfigText) failed for wg10 or wg2.")
        }
        guard scratchStore.tunnels.map(\.name) == ["wg2", "wg10"] else {
            throw CheckError(message: "Natural sort failed: \(scratchStore.tunnels.map(\.name))")
        }

        let editor = TunnelEditorViewModel()
        editor.generateKeyPair()
        let firstKey = editor.privateKey
        editor.generateKeyPair()
        guard !firstKey.isEmpty, editor.privateKey != firstKey, !editor.publicKey.isEmpty else {
            throw CheckError(message: "TunnelEditorViewModel keypair generation/regeneration failed.")
        }
        guard await scratchStore.importConfigText(pasteText, named: "   ") == false,
              await scratchStore.importConfigText(pasteText, named: "wg2") == false else {
            throw CheckError(message: "Empty or duplicate tunnel name was not rejected.")
        }
    }

    static func measure(_ id: AutomatedCheckID, body: () throws -> CheckPayload) -> AutomatedCheckResult {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let payload = try body()
            return AutomatedCheckResult(
                id: id,
                status: payload.status,
                summary: payload.summary,
                detail: payload.detail,
                durationMilliseconds: durationMs(since: start, clock: clock)
            )
        } catch {
            return AutomatedCheckResult(
                id: id,
                status: .failed,
                summary: error.localizedDescription,
                detail: String(describing: error),
                durationMilliseconds: durationMs(since: start, clock: clock)
            )
        }
    }

    static func durationMs(since start: ContinuousClock.Instant, clock: ContinuousClock) -> Int {
        let duration = start.duration(to: clock.now)
        let secondsMs = Int(duration.components.seconds) * 1000
        let attoMs = Int(duration.components.attoseconds / 1_000_000_000_000_000)
        return max(0, secondsMs + attoMs)
    }
}
#endif
