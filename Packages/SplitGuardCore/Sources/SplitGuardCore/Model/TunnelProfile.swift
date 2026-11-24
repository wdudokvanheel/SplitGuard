// SPDX-License-Identifier: MIT

import Foundation
import WireGuardEngine

public enum TunnelProfileError: Error, Equatable, LocalizedError, Sendable {
    case duplicatePeerPublicKey
    case unsupportedMTU(UInt16)

    public var errorDescription: String? {
        switch self {
        case .duplicatePeerPublicKey:
            return "Two or more peers have the same public key."
        case .unsupportedMTU(let value):
            return InterfaceConfiguration.invalidMTUDescription(String(value))
        }
    }
}

public struct TunnelProfile: Equatable, Sendable {
    public var name: String
    public var interface: InterfaceConfiguration
    public var peers: [PeerConfiguration]
    public var splitDNS: SplitDNSConfiguration
    public var options: TunnelOptions

    public init(
        name: String = "",
        interface: InterfaceConfiguration,
        peers: [PeerConfiguration] = [],
        splitDNS: SplitDNSConfiguration = .allDomains,
        options: TunnelOptions = .default
    ) throws {
        var seenPublicKeys = Set<WireGuardPublicKey>()
        for peer in peers {
            guard seenPublicKeys.insert(peer.publicKey).inserted else {
                throw TunnelProfileError.duplicatePeerPublicKey
            }
        }

        let routesAllIPv4 = Self.routesAllIPv4Traffic(allowedIPs: peers.flatMap(\.allowedIPs))
        self.name = name
        self.interface = interface
        self.peers = peers
        self.splitDNS = splitDNS
        self.options = options.sanitized(routesAllIPv4: routesAllIPv4)
    }

    public var routesAllIPv4Traffic: Bool {
        Self.routesAllIPv4Traffic(allowedIPs: peers.flatMap(\.allowedIPs))
    }

    public var routesAllIPv6Traffic: Bool {
        Self.routesAllIPv6Traffic(allowedIPs: peers.flatMap(\.allowedIPs))
    }

    public static func routesAllIPv4Traffic(allowedIPs: [IPPrefix]) -> Bool {
        var hasLowerHalf = false
        var hasUpperHalf = false

        for prefix in allowedIPs {
            guard !prefix.address.isIPv6 else { continue }
            if prefix.length == 0 {
                return true
            }
            if prefix.length == 1 {
                let firstByte = prefix.address.bytes.first
                if firstByte == 0x00 {
                    hasLowerHalf = true
                } else if firstByte == 0x80 {
                    hasUpperHalf = true
                }
            }
        }
        return hasLowerHalf && hasUpperHalf
    }

    public static func routesAllIPv6Traffic(allowedIPs: [IPPrefix]) -> Bool {
        var hasLowerHalf = false
        var hasUpperHalf = false

        for prefix in allowedIPs {
            guard prefix.address.isIPv6 else { continue }
            if prefix.length == 0 {
                return true
            }
            if prefix.length == 1 {
                let firstByte = prefix.address.bytes.first
                if firstByte == 0x00 {
                    hasLowerHalf = true
                } else if firstByte == 0x80 {
                    hasUpperHalf = true
                }
            }
        }
        return hasLowerHalf && hasUpperHalf
    }
}
