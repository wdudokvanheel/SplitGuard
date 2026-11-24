// SPDX-License-Identifier: MIT

import Foundation
import Network
import WireGuardEngine
import WireGuardKit

public enum TunnelConfigurationConversionError: Error, Equatable, Sendable {
    case invalidPrivateKey
    case invalidPublicKey
    case invalidPresharedKey
    case invalidAllowedIP(String)
    case unresolvedEndpoint(String)
    case mismatchedEndpointCount(expected: Int, actual: Int)
}

public extension TunnelConfiguration {
    /// Converts a `WireGuardKit.TunnelConfiguration` and its already-resolved peer endpoints
    /// directly into a typed `WireGuardEngine.DeviceConfiguration` without hex/UAPI serialization.
    func makeDeviceConfiguration(resolvedEndpoints: [Endpoint?]) throws -> DeviceConfiguration {
        guard resolvedEndpoints.count == peers.count else {
            throw TunnelConfigurationConversionError.mismatchedEndpointCount(
                expected: peers.count,
                actual: resolvedEndpoints.count
            )
        }
        guard let privateKey = WireGuardPrivateKey(rawValue: interface.privateKey.rawValue) else {
            throw TunnelConfigurationConversionError.invalidPrivateKey
        }

        var devicePeers: [DevicePeerConfiguration] = []
        devicePeers.reserveCapacity(peers.count)

        for (peer, resolvedEndpoint) in zip(peers, resolvedEndpoints) {
            guard let publicKey = WireGuardPublicKey(rawValue: peer.publicKey.rawValue) else {
                throw TunnelConfigurationConversionError.invalidPublicKey
            }

            let presharedKey: WireGuardPresharedKey?
            if let rawPSK = peer.preSharedKey?.rawValue {
                guard let converted = WireGuardPresharedKey(rawValue: rawPSK) else {
                    throw TunnelConfigurationConversionError.invalidPresharedKey
                }
                presharedKey = converted
            } else {
                presharedKey = nil
            }

            let ipEndpoint: IPEndpoint?
            if let resolvedEndpoint {
                guard let converted = resolvedEndpoint.toIPEndpoint() else {
                    throw TunnelConfigurationConversionError.unresolvedEndpoint(resolvedEndpoint.stringRepresentation)
                }
                ipEndpoint = converted
            } else {
                ipEndpoint = nil
            }

            var allowedIPs: [IPPrefix] = []
            allowedIPs.reserveCapacity(peer.allowedIPs.count)
            for range in peer.allowedIPs {
                guard let prefix = range.toIPPrefix() else {
                    throw TunnelConfigurationConversionError.invalidAllowedIP(range.stringRepresentation)
                }
                allowedIPs.append(prefix)
            }

            devicePeers.append(DevicePeerConfiguration(
                publicKey: publicKey,
                presharedKey: presharedKey,
                endpoint: ipEndpoint,
                allowedIPs: allowedIPs,
                persistentKeepalive: peer.persistentKeepAlive ?? 0
            ))
        }

        return DeviceConfiguration(
            privateKey: privateKey,
            listenPort: interface.listenPort,
            firewallMark: nil,
            peers: devicePeers
        )
    }

    /// Builds a typed endpoint update map for `WireGuardDevice.updateEndpoints(_:)` from
    /// already-resolved endpoints, skipping peers with unresolved hostnames.
    func endpointUpdates(resolvedEndpoints: [Endpoint?]) -> [WireGuardPublicKey: IPEndpoint?] {
        var updates: [WireGuardPublicKey: IPEndpoint?] = [:]
        updates.reserveCapacity(peers.count)
        for (peer, endpoint) in zip(peers, resolvedEndpoints) {
            guard let publicKey = WireGuardPublicKey(rawValue: peer.publicKey.rawValue) else { continue }
            if let endpoint {
                if let ipEndpoint = endpoint.toIPEndpoint() {
                    updates[publicKey] = ipEndpoint
                }
            } else {
                updates[publicKey] = nil
            }
        }
        return updates
    }

    /// Builds a typed endpoint update map for path-change re-resolution results.
    /// Peers whose endpoint re-resolution failed or that have no configured endpoint are omitted
    /// so their current runtime endpoint is preserved.
    static func endpointUpdates(
        from reresolved: [(WireGuardKit.PeerConfiguration, EndpointResolutionResult?)]
    ) -> [WireGuardPublicKey: IPEndpoint?] {
        var updates: [WireGuardPublicKey: IPEndpoint?] = [:]
        updates.reserveCapacity(reresolved.count)
        for (peer, result) in reresolved {
            guard case .some(.success((_, let resolvedEndpoint))) = result,
                  let publicKey = WireGuardPublicKey(rawValue: peer.publicKey.rawValue),
                  let ipEndpoint = resolvedEndpoint.toIPEndpoint() else {
                continue
            }
            updates[publicKey] = ipEndpoint
        }
        return updates
    }
}

extension Endpoint {
    func toIPEndpoint() -> IPEndpoint? {
        switch host {
        case .ipv4(let address):
            guard let ip = WireGuardEngine.IPAddress(bytes: address.rawValue) else { return nil }
            return IPEndpoint(address: ip, port: port.rawValue)
        case .ipv6(let address):
            let zoneID = address.interface?.name
            guard let ip = WireGuardEngine.IPAddress(bytes: address.rawValue, zoneID: zoneID) else { return nil }
            return IPEndpoint(address: ip, port: port.rawValue)
        case .name:
            return nil
        @unknown default:
            return nil
        }
    }
}

extension IPAddressRange {
    func toIPPrefix() -> IPPrefix? {
        guard let ip = WireGuardEngine.IPAddress(bytes: address.rawValue) else { return nil }
        return IPPrefix(address: ip, length: Int(networkPrefixLength))
    }
}
