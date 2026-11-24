// SPDX-License-Identifier: MIT

import Foundation
import NetworkExtension
import Security

public enum ProfileStoreError: Error, Equatable, LocalizedError, Sendable {
    case keychainAddFailed(OSStatus)
    case keychainLoadFailed(OSStatus)
    case invalidUTF8Data
    case missingPasswordReference

    public var errorDescription: String? {
        switch self {
        case .keychainAddFailed(let status):
            return "Unable to save tunnel profile to keychain (OSStatus \(status))."
        case .keychainLoadFailed(let status):
            return "Unable to load tunnel profile from keychain (OSStatus \(status))."
        case .invalidUTF8Data:
            return "Stored tunnel profile is not valid UTF-8 text."
        case .missingPasswordReference:
            return "Tunnel protocol configuration is missing a keychain reference."
        }
    }
}

public protocol KeychainStore: Sendable {
    func add(
        data: Data,
        label: String,
        account: String,
        service: String,
        description: String,
        accessGroup: String?
    ) throws -> Data
    func load(reference: Data) throws -> Data
    func delete(reference: Data)
    func exists(reference: Data) -> Bool
    func allReferences(service: String, accessGroup: String?) -> [Data]
}

public struct SystemKeychainStore: KeychainStore {
    public init() {}

    public func add(
        data: Data,
        label: String,
        account: String,
        service: String,
        description: String,
        accessGroup: String?
    ) throws -> Data {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrLabel: label,
            kSecAttrAccount: account,
            kSecAttrDescription: description,
            kSecAttrService: service,
            kSecValueData: data,
            kSecReturnPersistentRef: true,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        if let accessGroup, !accessGroup.isEmpty {
            query[kSecAttrAccessGroup] = accessGroup
        }

        var result: CFTypeRef?
        let status = SecItemAdd(query as CFDictionary, &result)
        guard status == errSecSuccess, let reference = result as? Data else {
            Log.error("Unable to add profile to keychain: \(status)")
            throw ProfileStoreError.keychainAddFailed(status)
        }
        return reference
    }

    public func load(reference: Data) throws -> Data {
        let query: [CFString: Any] = [
            kSecValuePersistentRef: reference,
            kSecReturnData: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            Log.error("Unable to load profile from keychain: \(status)")
            throw ProfileStoreError.keychainLoadFailed(status)
        }
        return data
    }

    public func delete(reference: Data) {
        let status = SecItemDelete([kSecValuePersistentRef: reference] as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.error("Unable to delete profile from keychain: \(status)")
        }
    }

    public func exists(reference: Data) -> Bool {
        let status = SecItemCopyMatching([kSecValuePersistentRef: reference] as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    public func allReferences(service: String, accessGroup: String?) -> [Data] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnPersistentRef: true
        ]
        if let accessGroup, !accessGroup.isEmpty {
            query[kSecAttrAccessGroup] = accessGroup
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [Data] else {
            return []
        }
        return items
    }
}

public struct ProfileStore: Sendable {
    private static let extensionSuffix = ".network-extension"
    private static let defaultServiceName = "com.bitechular.splitguard"

    public let keychain: any KeychainStore
    public let service: String
    public let accessGroup: String?

    public init(
        keychain: any KeychainStore = SystemKeychainStore(),
        service: String,
        accessGroup: String? = nil
    ) {
        self.keychain = keychain
        self.service = service
        self.accessGroup = accessGroup
    }

    public init(
        keychain: any KeychainStore = SystemKeychainStore(),
        bundle: Bundle = .main
    ) {
        self.init(
            keychain: keychain,
            service: Self.defaultService(for: bundle),
            accessGroup: AppGroup.identifier(in: bundle)
        )
    }

    public static func defaultService(for bundle: Bundle = .main) -> String {
        guard var identifier = bundle.bundleIdentifier, !identifier.isEmpty else {
            return defaultServiceName
        }
        if identifier.hasSuffix(extensionSuffix) {
            identifier.removeLast(extensionSuffix.count)
        }
        return identifier
    }

    public static func serverAddress(for profile: TunnelProfile) -> String {
        let endpoints = profile.peers.compactMap(\.endpoint)
        switch endpoints.count {
        case 0:
            return "Unspecified"
        case 1:
            return endpoints[0].description
        default:
            return "Multiple endpoints"
        }
    }

    public func save(_ profile: TunnelProfile, replacing oldReference: Data? = nil) throws -> Data {
        let serialized = TunnelProfileCodec.serialize(profile)
        let data = Data(serialized.utf8)
        let newReference = try keychain.add(
            data: data,
            label: "SplitGuard Tunnel: \(profile.name)",
            account: "\(profile.name): \(UUID().uuidString)",
            service: service,
            description: "SplitGuard tunnel profile",
            accessGroup: accessGroup
        )
        if let oldReference {
            keychain.delete(reference: oldReference)
        }
        return newReference
    }

    public func load(reference: Data, name: String = "") throws -> TunnelProfile {
        let data = try keychain.load(reference: reference)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProfileStoreError.invalidUTF8Data
        }
        return try TunnelProfileCodec.parse(text, name: name)
    }

    public func delete(reference: Data) {
        keychain.delete(reference: reference)
    }

    public func verify(reference: Data) -> Bool {
        keychain.exists(reference: reference)
    }

    public func deleteOrphaned(keeping activeReferences: Set<Data>) {
        for reference in keychain.allReferences(service: service, accessGroup: accessGroup)
        where !activeReferences.contains(reference) {
            keychain.delete(reference: reference)
        }
    }

    public func makeProtocol(
        for profile: TunnelProfile,
        providerBundleIdentifier: String,
        replacing oldReference: Data? = nil
    ) throws -> NETunnelProviderProtocol {
        let reference = try save(profile, replacing: oldReference)
        let protocolConfiguration = NETunnelProviderProtocol()
        protocolConfiguration.providerBundleIdentifier = providerBundleIdentifier
        protocolConfiguration.passwordReference = reference
        protocolConfiguration.providerConfiguration = nil
        protocolConfiguration.serverAddress = Self.serverAddress(for: profile)
        protocolConfiguration.applyKillSwitch(profile.options.sanitized(for: profile))
        return protocolConfiguration
    }

    public func loadProfile(
        from protocolConfiguration: NETunnelProviderProtocol,
        name: String = ""
    ) throws -> TunnelProfile {
        guard let reference = protocolConfiguration.passwordReference else {
            throw ProfileStoreError.missingPasswordReference
        }
        return try load(reference: reference, name: name)
    }
}

public extension NETunnelProviderProtocol {
    func applyKillSwitch(_ options: TunnelOptions) {
        if options.killSwitch.isEnabled {
            includeAllNetworks = true
            excludeLocalNetworks = options.killSwitch.allowLocalNetwork
        } else {
            includeAllNetworks = false
            excludeLocalNetworks = false
        }
        if #available(iOS 16.4, macOS 13.3, *) {
            excludeCellularServices = true
            excludeAPNs = true
        }
        if #available(iOS 17.4, macOS 14.4, *) {
            excludeDeviceCommunication = true
        }
    }
}
