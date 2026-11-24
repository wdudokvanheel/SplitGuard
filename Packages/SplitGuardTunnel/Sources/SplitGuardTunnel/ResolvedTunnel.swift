// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import SplitGuardCore
import WireGuardEngine

public enum ResolvedTunnelError: Error, Equatable, Sendable {
    case mismatchedEndpointCount(expected: Int, actual: Int)
}

public struct ResolvedTunnel: Equatable, Sendable {
    public let profile: TunnelProfile
    public var endpoints: [IPEndpoint?]

    public init(profile: TunnelProfile, endpoints: [IPEndpoint?]) {
        self.profile = profile
        self.endpoints = endpoints
    }

    public func makeDeviceConfiguration() throws -> DeviceConfiguration {
        guard endpoints.count == profile.peers.count else {
            throw ResolvedTunnelError.mismatchedEndpointCount(
                expected: profile.peers.count,
                actual: endpoints.count
            )
        }

        let devicePeers = zip(profile.peers, endpoints).map { peer, endpoint in
            DevicePeerConfiguration(
                publicKey: peer.publicKey,
                presharedKey: peer.presharedKey,
                endpoint: endpoint,
                allowedIPs: peer.allowedIPs,
                persistentKeepalive: peer.persistentKeepalive ?? 0
            )
        }

        return DeviceConfiguration(
            privateKey: profile.interface.privateKey,
            listenPort: profile.interface.listenPort,
            firewallMark: nil,
            peers: devicePeers
        )
    }

    public func reresolveEndpoints(
        using reresolve: (IPEndpoint) throws -> IPEndpoint = EndpointResolver.reresolve
    ) -> [(WireGuardPublicKey, Result<IPEndpoint, EndpointResolutionError>?)] {
        zip(profile.peers, endpoints).map { peer, endpoint in
            guard let endpoint else {
                return (peer.publicKey, nil)
            }
            do {
                return (peer.publicKey, .success(try reresolve(endpoint)))
            } catch let error as EndpointResolutionError {
                return (peer.publicKey, .failure(error))
            } catch {
                return (peer.publicKey, .failure(EndpointResolutionError(
                    errorCode: EAI_FAIL,
                    address: endpoint.address.description
                )))
            }
        }
    }

    /// Builds a typed endpoint update map for path-change re-resolution results.
    /// Peers whose re-resolution failed or that have no configured endpoint are omitted
    /// so their current runtime endpoint is preserved.
    public static func endpointUpdates(
        from reresolved: [(WireGuardPublicKey, Result<IPEndpoint, EndpointResolutionError>?)]
    ) -> [WireGuardPublicKey: IPEndpoint?] {
        var updates: [WireGuardPublicKey: IPEndpoint?] = [:]
        updates.reserveCapacity(reresolved.count)
        for (publicKey, result) in reresolved {
            guard case .some(.success(let endpoint)) = result else {
                continue
            }
            updates[publicKey] = endpoint
        }
        return updates
    }
}
