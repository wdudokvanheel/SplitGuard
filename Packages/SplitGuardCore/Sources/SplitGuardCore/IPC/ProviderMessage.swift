// SPDX-License-Identifier: MIT

import Foundation
import WireGuardEngine

public enum ProviderMessage: Codable, Equatable, Sendable {
    case status
    case lastStartError
    case updateLocalSettings(TunnelLocalSettings)
    case debugPhysicalDNSProbe(name: String)

    public func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(from data: Data) throws -> ProviderMessage {
        try JSONDecoder().decode(ProviderMessage.self, from: data)
    }
}

public struct PhysicalDNSProbeResult: Codable, Equatable, Sendable {
    public var name: String
    public var interfaceIndex: UInt32?
    public var responseCode: UInt8?
    public var records: [String]
    public var error: String?

    public init(
        name: String,
        interfaceIndex: UInt32? = nil,
        responseCode: UInt8? = nil,
        records: [String] = [],
        error: String? = nil
    ) {
        self.name = name
        self.interfaceIndex = interfaceIndex
        self.responseCode = responseCode
        self.records = records
        self.error = error
    }
}

public enum ProviderReply: Codable, Equatable, Sendable {
    case status(DeviceStatus)
    case lastStartError(TunnelStartError?)
    case acknowledged
    case debugPhysicalDNSProbe(PhysicalDNSProbeResult)

    public func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(from data: Data) throws -> ProviderReply {
        try JSONDecoder().decode(ProviderReply.self, from: data)
    }
}

public enum TunnelStartError: Error, Codable, Equatable, Hashable, LocalizedError, CustomNSError, Sendable {
    case invalidConfiguration
    case dnsResolutionFailed(hostnames: [String])
    case networkSettingsFailed(String?)
    case engineStartFailed(String?)

    public static let errorDomain = "com.bitechular.splitguard.TunnelStartError"

    private static let hostnamesUserInfoKey = "SplitGuardHostnames"
    private static let detailUserInfoKey = "SplitGuardDetail"

    private static let invalidConfigurationCode = 1
    private static let dnsResolutionFailedCode = 2
    private static let networkSettingsFailedCode = 3
    private static let engineStartFailedCode = 4

    public var title: String {
        switch self {
        case .invalidConfiguration:
            return "Invalid tunnel configuration"
        case .dnsResolutionFailed:
            return "Endpoint DNS resolution failed"
        case .networkSettingsFailed:
            return "Failed to apply network settings"
        case .engineStartFailed:
            return "Failed to start tunnel engine"
        }
    }

    public var message: String {
        switch self {
        case .invalidConfiguration:
            return "The saved tunnel configuration could not be loaded."
        case .dnsResolutionFailed(let hostnames):
            let cleaned = hostnames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if cleaned.isEmpty {
                return "Could not resolve one or more peer endpoint hostnames."
            }
            return "Could not resolve endpoint hostname(s): \(cleaned.joined(separator: ", "))."
        case .networkSettingsFailed(let detail):
            if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Could not configure tunnel network settings: \(detail)"
            }
            return "Could not configure tunnel network settings."
        case .engineStartFailed(let detail):
            if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Could not start the WireGuard engine: \(detail)"
            }
            return "Could not start the WireGuard engine."
        }
    }

    public var errorDescription: String? {
        message
    }

    public var errorCode: Int {
        switch self {
        case .invalidConfiguration:
            return Self.invalidConfigurationCode
        case .dnsResolutionFailed:
            return Self.dnsResolutionFailedCode
        case .networkSettingsFailed:
            return Self.networkSettingsFailedCode
        case .engineStartFailed:
            return Self.engineStartFailedCode
        }
    }

    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = [
            NSLocalizedDescriptionKey: message,
            NSLocalizedFailureReasonErrorKey: title
        ]
        switch self {
        case .invalidConfiguration:
            break
        case .dnsResolutionFailed(let hostnames):
            info[Self.hostnamesUserInfoKey] = hostnames
        case .networkSettingsFailed(let detail), .engineStartFailed(let detail):
            if let detail {
                info[Self.detailUserInfoKey] = detail
            }
        }
        return info
    }

    public init?(nsError: NSError) {
        if let decoded = Self.decodeDirect(nsError) {
            self = decoded
            return
        }
        var current: NSError? = nsError
        for _ in 0..<8 {
            guard let candidate = current else { break }
            if let underlying = candidate.userInfo[NSUnderlyingErrorKey] as? NSError {
                if let decoded = Self.decodeDirect(underlying) {
                    self = decoded
                    return
                }
                current = underlying
                continue
            }
            if let multiple = candidate.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
                for item in multiple {
                    if let decoded = TunnelStartError(nsError: item) {
                        self = decoded
                        return
                    }
                }
            }
            break
        }
        return nil
    }

    private static func decodeDirect(_ nsError: NSError) -> TunnelStartError? {
        guard nsError.domain == errorDomain else { return nil }
        switch nsError.code {
        case invalidConfigurationCode:
            return .invalidConfiguration
        case dnsResolutionFailedCode:
            let hostnames = nsError.userInfo[hostnamesUserInfoKey] as? [String] ?? []
            return .dnsResolutionFailed(hostnames: hostnames)
        case networkSettingsFailedCode:
            return .networkSettingsFailed(nsError.userInfo[detailUserInfoKey] as? String)
        case engineStartFailedCode:
            return .engineStartFailed(nsError.userInfo[detailUserInfoKey] as? String)
        default:
            return nil
        }
    }
}

#if DEBUG && os(iOS) && !targetEnvironment(simulator)
public enum DebugCacheProbeMessage {
    public static let startOption = "debugEndpointCacheProbeReference"
    public static let request = Data("SplitGuard.Debug.cachedAddressUsed".utf8)
}
#endif
