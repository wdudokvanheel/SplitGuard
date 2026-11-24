// SPDX-License-Identifier: MIT

#if DEBUG && os(iOS) && !targetEnvironment(simulator)
import Foundation
import NetworkExtension
import SplitGuardCore
import WireGuardEngine

/// For the wizard reconnect only, fail resolution of its single configured hostname.
public final class DebugEndpointCacheProbe: EndpointCaching, @unchecked Sendable {
    private let cache = FileEndpointCache()
    private let lock = NSLock()
    private var blockedHost: String?
    private var selectedAddress: String?

    public init() {}

    public func begin(blocking hostname: String?) {
        lock.withLock {
            blockedHost = hostname
            selectedAddress = nil
        }
    }

    public var cachedAddressUsed: String? {
        lock.withLock { selectedAddress }
    }

    public func cachedEndpoint(for hostname: String, port: UInt16) -> IPEndpoint? {
        let endpoint = cache.cachedEndpoint(for: hostname, port: port)
        lock.withLock {
            if hostname == blockedHost { selectedAddress = endpoint?.address.description }
        }
        return endpoint
    }

    public func store(resolvedEndpoint: IPEndpoint, for hostname: String) {
        cache.store(resolvedEndpoint: resolvedEndpoint, for: hostname)
    }

    public func makeController(
        provider: NEPacketTunnelProvider,
        logHandler: @escaping @Sendable (TunnelLogLevel, String) -> Void
    ) -> TunnelController {
        TunnelController(provider: provider as any TunnelProviderHost, endpointCache: self, resolveEndpoints: { [self] endpoints in
            guard let hostname = lock.withLock({ blockedHost }) else { return EndpointResolver.resolve(endpoints) }
            // Replace the fixture hostname before dispatching any real DNS lookups.
            let results = EndpointResolver.resolve(endpoints.map { $0?.hostname == hostname ? nil : $0 })
            return zip(endpoints, results).map { endpoint, result in
                endpoint?.hostname == hostname ? .failure(.init(errorCode: EAI_AGAIN, address: hostname)) : result
            }
        }, logHandler: logHandler)
    }
}
#endif
