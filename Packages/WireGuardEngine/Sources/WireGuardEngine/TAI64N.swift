// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// WireGuard's TAI64N timestamp encoding and ordering from tai64n/tai64n.go.
struct TAI64N: Comparable {
    static let length = 12
    private static let base: UInt64 = 0x400000000000000a
    private static let whitenerMask: UInt32 = 0x00ff_ffff
    private static let nanosecondsPerSecond: Int64 = 1_000_000_000

    let rawRepresentation: Data

    init?(rawRepresentation: Data) {
        guard rawRepresentation.count == Self.length else { return nil }
        self.rawRepresentation = rawRepresentation
    }

    init(unixSeconds: Int64, nanoseconds: Int64) {
        // Normalize like Go time.Unix before masking the nanoseconds field.
        var seconds = unixSeconds &+ (nanoseconds / Self.nanosecondsPerSecond)
        var remainder = nanoseconds % Self.nanosecondsPerSecond
        if remainder < 0 {
            seconds &-= 1
            remainder += Self.nanosecondsPerSecond
        }
        let taiSeconds = Self.base &+ UInt64(bitPattern: seconds)
        let whitened = UInt32(remainder) & ~Self.whitenerMask

        var raw = Data(capacity: Self.length)
        withUnsafeBytes(of: taiSeconds.bigEndian) { raw.append(contentsOf: $0) }
        withUnsafeBytes(of: whitened.bigEndian) { raw.append(contentsOf: $0) }
        rawRepresentation = raw
    }

    static func now() -> Self {
        var time = timespec()
        let status = clock_gettime(CLOCK_REALTIME, &time)
        precondition(status == 0)
        return Self(unixSeconds: Int64(time.tv_sec), nanoseconds: Int64(time.tv_nsec))
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawRepresentation.lexicographicallyPrecedes(rhs.rawRepresentation)
    }
}
