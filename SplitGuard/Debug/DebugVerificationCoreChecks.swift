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
            let zipByteCount = try verifyZipArchiveExport(primaryProfile: parsed, fileManager: fileManager)
            let details = [
                "Codec round-trip passed (IPv4/IPv6, hostnames, host-bit masking, # SplitGuard: directives).",
                "PKZIP verified (\(zipByteCount) bytes, contains CodecProbe.conf & SecondProbe.conf).",
                "Temp staging cleanup verified (0 SplitGuardExport-* directories left)."
            ].joined(separator: "\n")
            return CheckPayload(
                status: .passed,
                summary: "Codec round-trip & PKZIP export verified (\(zipByteCount) bytes)",
                detail: details
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
}
#endif
