// SPDX-License-Identifier: MIT

import Foundation
import Network
import WireGuardKit

public protocol EndpointCaching: Sendable {
    func cachedEndpoint(for hostname: String, port: NWEndpoint.Port) -> Endpoint?
    func store(resolvedEndpoint: Endpoint, for hostname: String)
}

/// Persists the last successfully resolved IP address per endpoint hostname in a small JSON
/// file in the extension's container so kill-switch startups can proceed when DNS is blocked.
public final class FileEndpointCache: EndpointCaching, @unchecked Sendable {
    private let fileURL: URL?
    private let lock = NSLock()
    private var entries: [String: String] = [:]

    public static func defaultCacheURL() -> URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("splitguard-endpoint-cache.json")
    }

    public init(fileURL: URL? = FileEndpointCache.defaultCacheURL()) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.entries = decoded
        }
    }

    public func cachedEndpoint(for hostname: String, port: NWEndpoint.Port) -> Endpoint? {
        let key = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let rawIP = lock.withLock({ entries[key] }) else { return nil }
        if let v4 = IPv4Address(rawIP) {
            return Endpoint(host: .ipv4(v4), port: port)
        }
        if let v6 = IPv6Address(rawIP) {
            return Endpoint(host: .ipv6(v6), port: port)
        }
        return nil
    }

    public func store(resolvedEndpoint: Endpoint, for hostname: String) {
        let ipString: String
        switch resolvedEndpoint.host {
        case .ipv4(let address):
            ipString = "\(address)"
        case .ipv6(let address):
            ipString = "\(address)"
        case .name:
            return
        @unknown default:
            return
        }

        let key = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let snapshot: [String: String]? = lock.withLock {
            guard entries[key] != ipString else { return nil }
            entries[key] = ipString
            return entries
        }

        guard let snapshot, let fileURL else { return }
        if let encoded = try? JSONEncoder().encode(snapshot) {
            let parent = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }
}
