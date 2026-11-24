// SPDX-License-Identifier: MIT

import Foundation
import WireGuardEngine

public protocol EndpointCaching: Sendable {
    func cachedEndpoint(for hostname: String, port: UInt16) -> IPEndpoint?
    func store(resolvedEndpoint: IPEndpoint, for hostname: String)
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

    public func cachedEndpoint(for hostname: String, port: UInt16) -> IPEndpoint? {
        let key = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let rawIP = lock.withLock({ entries[key] }),
              let address = IPAddress(rawIP) else {
            return nil
        }
        return IPEndpoint(address: address, port: port)
    }

    public func store(resolvedEndpoint: IPEndpoint, for hostname: String) {
        let ipString = resolvedEndpoint.address.description
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
