// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Foundation

final class HandshakeRateLimiter: @unchecked Sendable {
    private static let packetCost: UInt64 = 1_000_000_000 / 20
    private static let maxTokens = 5 * packetCost
    static let collectionInterval: UInt64 = 1_000_000_000

    private struct Entry {
        var lastTime: ProtocolInstant
        var tokens: UInt64
    }

    private let lock = NSLock()
    private let now: () -> ProtocolInstant
    private let maximumEntries: Int
    private var table: [IPAddress: Entry] = [:]

    init(now: @escaping () -> ProtocolInstant, maximumEntries: Int = Int.max) {
        self.now = now
        self.maximumEntries = maximumEntries
    }

    func reset() {
        lock.withLock { table.removeAll() }
    }

    func allow(_ address: IPAddress) -> Bool {
        lock.withLock {
            let instant = now()
            guard var entry = table[address] else {
                guard table.count < maximumEntries else { return false }
                table[address] = Entry(lastTime: instant, tokens: Self.maxTokens - Self.packetCost)
                return true
            }
            let refill = min(instant.elapsed(since: entry.lastTime), Self.maxTokens)
            entry.tokens = min(entry.tokens + refill, Self.maxTokens)
            entry.lastTime = instant

            // The pinned implementation uses a strict comparison.
            let allowed = entry.tokens > Self.packetCost
            if allowed { entry.tokens -= Self.packetCost }
            table[address] = entry
            return allowed
        }
    }

    /// Called by the device's timer path. Returns true if the table is empty.
    @discardableResult
    func collectStaleEntries() -> Bool {
        lock.withLock {
            let instant = now()
            table = table.filter { instant.elapsed(since: $0.value.lastTime) <= Self.collectionInterval }
            return table.isEmpty
        }
    }
}
