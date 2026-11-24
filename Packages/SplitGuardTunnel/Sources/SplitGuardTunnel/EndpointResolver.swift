// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Darwin
import Dispatch
import Foundation
import SplitGuardCore
import WireGuardEngine

public struct EndpointResolutionError: Error, Equatable, LocalizedError, Sendable {
    public let errorCode: Int32
    public let address: String

    public init(errorCode: Int32, address: String) {
        self.errorCode = errorCode
        self.address = address
    }

    public var errorDescription: String? {
        String(cString: gai_strerror(errorCode))
    }
}

public enum EndpointResolver {
    private static let resolverQueue = DispatchQueue(
        label: "SplitGuard.EndpointResolver",
        qos: .default,
        attributes: .concurrent
    )

    public static func resolve(_ endpoints: [Endpoint?]) -> [Result<IPEndpoint, EndpointResolutionError>?] {
        if endpoints.allSatisfy({ $0 == nil || $0?.ipEndpoint != nil }) {
            return endpoints.map { endpoint in
                endpoint?.ipEndpoint.map { .success($0) }
            }
        }

        final class ResultsBox: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [Result<IPEndpoint, EndpointResolutionError>?]

            init(count: Int) {
                storage = Array(repeating: nil, count: count)
            }

            func set(_ value: Result<IPEndpoint, EndpointResolutionError>?, at index: Int) {
                lock.withLock {
                    storage[index] = value
                }
            }

            func snapshot() -> [Result<IPEndpoint, EndpointResolutionError>?] {
                lock.withLock { storage }
            }
        }

        let results = ResultsBox(count: endpoints.count)
        resolverQueue.sync {
            DispatchQueue.concurrentPerform(iterations: endpoints.count) { index in
                guard let endpoint = endpoints[index] else { return }
                let resolved = resolveResult(endpoint)
                results.set(resolved, at: index)
            }
        }
        return results.snapshot()
    }

    public static func resolve(_ endpoint: Endpoint) throws -> IPEndpoint {
        switch endpoint.host {
        case .ip(let address):
            return IPEndpoint(address: address, port: endpoint.port)
        case .name(let hostname):
            return try resolveHostname(hostname, port: endpoint.port)
        }
    }

    /// Re-resolves a numeric IP endpoint through `getaddrinfo` with `ai_flags = 0` so DNS64
    /// synthesis applies on IPv6-only NAT64 networks.
    public static func reresolve(_ endpoint: IPEndpoint) throws -> IPEndpoint {
        let hostname = endpoint.address.description

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        hints.ai_flags = 0

        var resultPointer: UnsafeMutablePointer<addrinfo>?
        defer {
            if let resultPointer {
                freeaddrinfo(resultPointer)
            }
        }

        let errorCode = getaddrinfo(hostname, "\(endpoint.port)", &hints, &resultPointer)
        if errorCode != 0 {
            throw EndpointResolutionError(errorCode: errorCode, address: hostname)
        }

        var cursor = resultPointer
        while let current = cursor?.pointee {
            cursor = current.ai_next
            if let address = ipAddress(from: current) {
                return IPEndpoint(address: address, port: endpoint.port)
            }
        }

        throw EndpointResolutionError(errorCode: EAI_NONAME, address: hostname)
    }

    private static func resolveResult(_ endpoint: Endpoint) -> Result<IPEndpoint, EndpointResolutionError> {
        do {
            return .success(try resolve(endpoint))
        } catch let error as EndpointResolutionError {
            return .failure(error)
        } catch {
            return .failure(EndpointResolutionError(
                errorCode: EAI_FAIL,
                address: endpoint.hostname ?? endpoint.description
            ))
        }
    }

    private static func resolveHostname(_ hostname: String, port: UInt16) throws -> IPEndpoint {
        var hints = addrinfo()
        hints.ai_flags = AI_ALL
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP

        var resultPointer: UnsafeMutablePointer<addrinfo>?
        defer {
            if let resultPointer {
                freeaddrinfo(resultPointer)
            }
        }

        let errorCode = getaddrinfo(hostname, "\(port)", &hints, &resultPointer)
        if errorCode != 0 {
            throw EndpointResolutionError(errorCode: errorCode, address: hostname)
        }

        var ipv4Address: IPAddress?
        var ipv6Address: IPAddress?

        var cursor = resultPointer
        while let current = cursor?.pointee {
            cursor = current.ai_next
            guard let address = ipAddress(from: current) else { continue }
            if !address.isIPv6 {
                ipv4Address = address
                break
            } else if ipv6Address == nil {
                ipv6Address = address
            }
        }

        if let ipv4Address {
            return IPEndpoint(address: ipv4Address, port: port)
        }
        if let ipv6Address {
            return IPEndpoint(address: ipv6Address, port: port)
        }
        throw EndpointResolutionError(errorCode: EAI_NONAME, address: hostname)
    }

    private static func ipAddress(from addrInfo: addrinfo) -> IPAddress? {
        guard let addr = addrInfo.ai_addr else { return nil }
        switch addrInfo.ai_family {
        case AF_INET:
            guard Int(addrInfo.ai_addrlen) >= MemoryLayout<sockaddr_in>.size else { return nil }
            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            return withUnsafeBytes(of: sin.sin_addr) { IPAddress(bytes: $0) }
        case AF_INET6:
            guard Int(addrInfo.ai_addrlen) >= MemoryLayout<sockaddr_in6>.size else { return nil }
            let sin6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            let zoneID = sin6.sin6_scope_id == 0 ? nil : String(sin6.sin6_scope_id)
            return withUnsafeBytes(of: sin6.sin6_addr) { IPAddress(bytes: $0, zoneID: zoneID) }
        default:
            return nil
        }
    }
}
