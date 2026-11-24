// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Darwin
import Foundation

/// An instant from the engine's injected sleep-inclusive clock, in nanoseconds.
/// Unix time used by the UAPI and TAI64N is kept separately.
struct ProtocolInstant: Comparable, Sendable {
    static let second: UInt64 = 1_000_000_000

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

    func advanced(by nanoseconds: UInt64) -> Self {
        let (sum, overflow) = self.nanoseconds.addingReportingOverflow(nanoseconds)
        return .init(nanoseconds: overflow ? UInt64.max : sum)
    }
}
