#if DEBUG
import Foundation
import NetworkExtension
import SplitGuardCore
import WireGuardEngine

extension DebugVerificationLiveChecks {
    static func splitDNSPassed(publicOK: Bool, apex: [String], internalAnswers: [String], probe: PhysicalDNSProbeResult?) -> Bool {
        let expectedApex = "217.62.60.90"
        return publicOK && Set(apex) == [expectedApex] && Set(internalAnswers) == ["10.0.0.10"]
            && probe?.name == "hw45.nl" && probe?.error == nil && (probe?.interfaceIndex ?? 0) > 0
            && probe?.responseCode == 0 && probe?.records.contains(expectedApex) == true
    }

    static func cacheReconnectPassed(handshake: Bool, forcedLookupFailure: Bool) -> Bool {
        handshake && forcedLookupFailure
    }

    static func verdictMismatches() -> [String] {
        let apex = ["217.62.60.90"]
        let internalIP = ["10.0.0.10"]
        let scoped = PhysicalDNSProbeResult(name: "hw45.nl", interfaceIndex: 12, responseCode: 0, records: apex)
        var failed = [String]()
        func check(_ name: String, _ publicOK: Bool, _ answers: [String], _ internalAnswers: [String],
                   _ probe: PhysicalDNSProbeResult?, expected: Bool = false) {
            if splitDNSPassed(publicOK: publicOK, apex: answers, internalAnswers: internalAnswers, probe: probe) != expected {
                failed.append(name)
            }
        }
        check("complete DNS evidence", true, apex, internalIP, scoped, expected: true)
        check("public lookup failed", false, apex, internalIP, scoped)
        check("wrong apex", true, internalIP, internalIP, scoped)
        check("missing internal answer", true, apex, [], scoped)
        check("wrong internal answer", true, apex, apex, scoped)
        check("missing physical reply", true, apex, internalIP, nil)
        var bad = scoped
        bad.interfaceIndex = nil
        check("missing interface", true, apex, internalIP, bad)
        bad = scoped
        bad.responseCode = 2
        check("failed physical lookup", true, apex, internalIP, bad)
        bad = scoped
        bad.records = internalIP
        check("wrong physical answer", true, apex, internalIP, bad)
        if cacheReconnectPassed(handshake: true, forcedLookupFailure: false) { failed.append("fresh DNS reconnect") }
        if !cacheReconnectPassed(handshake: true, forcedLookupFailure: true) { failed.append("cache fallback reconnect") }
        return failed
    }
}

extension DebugVerificationCoreChecks {
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
}

#if !targetEnvironment(simulator)
/// Use the real Keychain for CRUD, injecting exactly one inaccessible read.
private final class OneFailedRead: KeychainStore, @unchecked Sendable {
    private let system = SystemKeychainStore()
    private let lock = NSLock()
    private var pending = true

    func load(reference: Data) throws -> Data {
        let fail = lock.withLock {
            defer { pending = false }
            return pending
        }
        if fail { throw ProfileStoreError.keychainLoadFailed(errSecInteractionNotAllowed) }
        return try system.load(reference: reference)
    }

    // KeychainStore protocol signature.
    // swiftlint:disable:next function_parameter_count
    func add(data: Data, label: String, account: String, service: String, description: String, accessGroup: String?) throws -> Data {
        try system.add(data: data, label: label, account: account, service: service, description: description, accessGroup: accessGroup)
    }

    func delete(reference: Data) { system.delete(reference: reference) }
    func exists(reference: Data) -> Bool { system.exists(reference: reference) }
    func allReferences(service: String, accessGroup: String?) -> [Data] { system.allReferences(service: service, accessGroup: accessGroup) }
}

extension DebugVerificationNetworkChecks {
    static func runDeviceProfileRecovery(store: TunnelStore) async -> NetworkCheckOutcome {
        let id = AutomatedCheckID.transientProfileRead
        let start = ContinuousClock.now
        if let name = await activeNonProbeTunnelName() {
            return NetworkCheckOutcome(result: AutomatedCheckResult(id: id, status: .info, summary: "Active user tunnel: \(name)"))
        }
        let name = probeNamePrefix + UUID().uuidString
        let storage = ProfileStore(keychain: OneFailedRead(), service: name, accessGroup: AppGroup.identifier())
        var created: NETunnelProviderManager?
        await store.backend.setConfigurationChangeObservationPaused(true)
        let result: AutomatedCheckResult
        do {
            let manager = try await createTempManager(name: name, profileStore: storage)
            created = manager
            guard let ref = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference else {
                throw LiveCheckError("Disposable manager has no password reference")
            }
            let backend = SystemTunnelBackend(profileStore: storage) {
                try await NETunnelProviderManager.loadAllFromPreferences().filter {
                    $0.localizedDescription == name && ($0.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference == ref
                }
            }
            _ = try await backend.loadAll()
            let retry = try await backend.loadAll()
            guard retry.count == 1, let recovered = retry.first,
                  recovered.profile == (try storage.load(reference: ref, name: name)) else {
                throw LiveCheckError("Second reload could not recover the original manager and reference")
            }
            result = AutomatedCheckResult(id: id, status: .passed, summary: "Recovered original manager, reference and profile on retry",
                                          durationMilliseconds: durationMs(since: start, clock: ContinuousClock()))
        } catch {
            result = AutomatedCheckResult(id: id, status: .failed, summary: error.localizedDescription)
        }
        await cleanupManagers([created].compactMap { $0 }, profileStore: storage, store: store)
        // Covers a failed preference save after Keychain insertion. This service belongs only to this run.
        storage.deleteOrphaned(keeping: [])
        return NetworkCheckOutcome(result: result)
    }
}
#endif
#endif
