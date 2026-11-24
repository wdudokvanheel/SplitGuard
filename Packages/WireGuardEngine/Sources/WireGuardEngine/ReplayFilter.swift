// SPDX-License-Identifier: MIT

/// The reference counts in blocks of 64 bits and keeps one extra block in the ring.
struct ReplayFilter {
    private static let blockShift = 6
    private static let blockCount = 128
    static let windowSize: UInt64 = UInt64((blockCount - 1) << blockShift)
    static let rejectAfterMessages: UInt64 = UInt64.max - (1 << 13)

    private var last: UInt64 = 0
    private var ring = [UInt64](repeating: 0, count: blockCount)

    mutating func reset() {
        last = 0
        ring[0] = 0
    }

    /// Call only after authenticating the packet. The counter limit is exclusive.
    mutating func validate(_ counter: UInt64, limit: UInt64 = Self.rejectAfterMessages) -> Bool {
        guard counter < limit else { return false }
        let block = counter >> Self.blockShift
        let ringMask = UInt64(Self.blockCount - 1)
        if counter > last {
            let current = last >> Self.blockShift
            let clearCount = min(block - current, UInt64(Self.blockCount))
            for step in 0..<clearCount {
                ring[Int((current + 1 + step) & ringMask)] = 0
            }
            last = counter
        } else if last - counter > Self.windowSize {
            return false
        }
        let slot = Int(block & ringMask)
        let bit = UInt64(1) << (counter & 63)
        let existing = ring[slot]
        ring[slot] = existing | bit
        return existing & bit == 0
    }
}
