// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Darwin
import Foundation

/// An instant from the engine's injected sleep-inclusive clock, in nanoseconds.
/// Unix time used by the UAPI and TAI64N is kept separately.
struct ProtocolInstant: Comparable {
    let nanoseconds: UInt64

    private static let timebase: mach_timebase_info_data_t = {
        var timebase = mach_timebase_info_data_t()
        let status = mach_timebase_info(&timebase)
        precondition(status == KERN_SUCCESS && timebase.denom != 0)
        return timebase
    }()

    static func now() -> Self {
        let ticks = mach_continuous_time()
        let scaled = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        let divisor = UInt64(timebase.denom)
        let nanoseconds = scaled.high < divisor ? divisor.dividingFullWidth(scaled).quotient : UInt64.max
        return Self(nanoseconds: nanoseconds)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    func elapsed(since earlier: Self) -> UInt64 {
        self >= earlier ? nanoseconds - earlier.nanoseconds : 0
    }
}

final class HandshakeRateLimiter {
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
