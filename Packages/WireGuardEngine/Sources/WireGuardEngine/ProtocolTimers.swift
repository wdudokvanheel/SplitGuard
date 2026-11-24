// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Darwin
import Dispatch
import Foundation

enum WireGuardTiming {
    static let rekeyAfterMessages: UInt64 = 1 << 60
    static let rekeyAfterTime = 120 * ProtocolInstant.second
    static let rejectAfterTime = 180 * ProtocolInstant.second
    static let rekeyTimeout = 5 * ProtocolInstant.second
    static let keepaliveTimeout = 10 * ProtocolInstant.second
    static let maxTimerHandshakes = 90 / 5
    static let zeroAfterTime = rejectAfterTime * 3
    static let underLoadAfterTime = ProtocolInstant.second
}

enum PeerTimer: CaseIterable, Hashable, Sendable {
    case retransmitHandshake, sendKeepalive, newHandshake, zeroKeyMaterial, persistentKeepalive
    // Immediate, coalesced work sent to the handshake queue by the outbound lane.
    case initiate
    case collectRateLimiter
}

struct PeerTimerKey: Hashable, Sendable {
    let peerID: ObjectIdentifier?
    let kind: PeerTimer

    init(_ peer: WireGuardPeer?, _ kind: PeerTimer) {
        peerID = peer.map(ObjectIdentifier.init)
        self.kind = kind
    }
}

/// Indexed min-heap. Replacing or cancelling a deadline removes its old entry immediately.
struct ProtocolDeadlines {
    struct Entry {
        let key: PeerTimerKey
        let peer: WireGuardPeer?
        let time: ProtocolInstant
    }

    private var heap: [Entry] = []
    private var positions: [PeerTimerKey: Int] = [:]

    var first: Entry? { heap.first }

    func contains(_ key: PeerTimerKey) -> Bool { positions[key] != nil }

    mutating func update(peer: WireGuardPeer?, kind: PeerTimer, time: ProtocolInstant?) {
        let key = PeerTimerKey(peer, kind)
        if let index = positions[key] {
            if let time {
                heap[index] = Entry(key: key, peer: peer, time: time)
                repair(index)
            } else {
                swap(index, heap.count - 1)
                heap.removeLast()
                positions[key] = nil
                if index < heap.count { repair(index) }
            }
        } else if let time {
            positions[key] = heap.count
            heap.append(Entry(key: key, peer: peer, time: time))
            repair(heap.count - 1)
        }
    }

    private mutating func repair(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].time < heap[parent].time else { break }
            swap(parent, child)
            child = parent
        }
        while child * 2 + 1 < heap.count {
            let left = child * 2 + 1
            let right = left + 1
            let earlier = right < heap.count && heap[right].time < heap[left].time ? right : left
            guard heap[earlier].time < heap[child].time else { break }
            swap(earlier, child)
            child = earlier
        }
    }

    private mutating func swap(_ first: Int, _ second: Int) {
        heap.swapAt(first, second)
        positions[heap[first].key] = first
        positions[heap[second].key] = second
    }
}

/// Abstracts the device's deadline wake mechanism between the production kqueue
/// continuous alarm and the deterministic manual scheduler used in unit tests.
protocol DeadlineScheduler: AnyObject, Sendable {
    func install(_ handler: @escaping @Sendable () -> Void)
    func arm(after delay: UInt64?)
    func consume()
    func wakeNow()
    func cancel()
}

/// Production deadline scheduler backed by a Mach continuous kqueue one-shot alarm.
final class ContinuousAlarmScheduler: DeadlineScheduler, @unchecked Sendable {
    let alarm: ContinuousAlarm

    var armCount: Int { alarm.armCount }
    var disarmCount: Int { alarm.disarmCount }

    init(queue: DispatchQueue) throws {
        alarm = try ContinuousAlarm(queue: queue)
    }

    func install(_ handler: @escaping @Sendable () -> Void) {
        alarm.install(handler)
    }

    func arm(after delay: UInt64?) {
        alarm.arm(after: delay)
    }

    func consume() {
        alarm.consume()
    }

    func wakeNow() {
        // Immediate deadlines already armed the continuous alarm for 0 ns.
    }

    func cancel() {
        alarm.cancel()
    }
}

/// Deterministic scheduler for tests that advance an injected clock manually.
/// Only immediate handshakes wake the handshake queue via a user-data source.
final class ManualDeadlineScheduler: DeadlineScheduler, @unchecked Sendable {
    private let wake: DispatchSourceUserDataAdd

    init(queue: DispatchQueue) {
        wake = DispatchSource.makeUserDataAddSource(queue: queue)
        wake.resume()
    }

    func install(_ handler: @escaping @Sendable () -> Void) {
        wake.setEventHandler(handler: handler)
    }

    func arm(after delay: UInt64?) {}

    func consume() {}

    func trigger() {
        wake.add(data: 1)
    }

    func wakeNow() {
        trigger()
    }

    func cancel() {
        wake.cancel()
    }

    deinit { cancel() }
}

/// One native one-shot alarm for all device deadlines. A Mach continuous kqueue timer
/// accrues sleep time and becomes readable upon wake. The engine re-reads its clock
/// on delivery, processing only deadlines that are actually due.
final class ContinuousAlarm: @unchecked Sendable {
    private let fd: Int32
    private let readable: DispatchSourceRead
    private let fallback: DispatchSourceTimer
    private(set) var armCount = 0
    private(set) var disarmCount = 0

    init(queue: DispatchQueue) throws {
        fd = kqueue()
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        readable = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        fallback = DispatchSource.makeTimerSource(queue: queue)
        fallback.schedule(deadline: .distantFuture)
        readable.setCancelHandler { [fd] in Darwin.close(fd) }
        readable.resume()
        fallback.resume()
    }

    func install(_ handler: @escaping @Sendable () -> Void) {
        readable.setEventHandler(handler: handler)
        fallback.setEventHandler(handler: handler)
    }

    func arm(after delay: UInt64?) {
        if delay == nil {
            disarmCount += 1
        } else {
            armCount += 1
        }
        let flags = delay == nil ? EV_DELETE : EV_ADD | EV_ONESHOT
        var change = kevent64_s(
            ident: 1, filter: Int16(EVFILT_TIMER), flags: UInt16(flags),
            fflags: UInt32(NOTE_NSECONDS | NOTE_MACH_CONTINUOUS_TIME),
            data: Int64(clamping: max(1, delay ?? 0)), udata: 0, ext: (0, 0)
        )
        var result: Int32
        repeat { result = kevent64(fd, &change, 1, nil, 0, 0, nil) } while result < 0 && errno == EINTR
        // Keep protocol deadlines continuous even on kernels which reject that timer flag.
        // The adapter can also call reevaluateDeadlines() upon a wake or path transition.
        if result < 0, let delay {
            fallback.schedule(deadline: .now() + .nanoseconds(Int(clamping: delay)))
        } else {
            fallback.schedule(deadline: .distantFuture)
        }
    }

    func consume() {
        var event = kevent64_s()
        var timeout = timespec()
        var result: Int32
        repeat { result = kevent64(fd, nil, 0, &event, 1, 0, &timeout) } while result < 0 && errno == EINTR
    }

    func cancel() {
        readable.cancel()
        fallback.cancel()
    }

    deinit { cancel() }
}
