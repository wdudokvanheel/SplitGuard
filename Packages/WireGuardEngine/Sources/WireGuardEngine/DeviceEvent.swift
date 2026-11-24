// SPDX-License-Identifier: MIT

import Darwin
import Dispatch
import Foundation

public enum DropReason: String, Codable, Sendable, Equatable {
    case noSession
    case noRoute
    case queueFull
    case stagedEvicted
    case invalidPacket
    case paused
    case hookDropped
    /// Packets in a failed adapter write batch. An adapter may have delivered a prefix of the batch.
    case tunnelWriteFailed
}

public enum DeviceEvent: Sendable, Equatable {
    case stateChanged(DeviceState)
    case healthChanged(WireGuardPublicKey, PeerHealth)
    case handshakeCompleted(WireGuardPublicKey, roundTrip: Duration?)
    case handshakeRetry(WireGuardPublicKey, attempt: Int)
    case handshakeGaveUp(WireGuardPublicKey)
    case endpointChanged(WireGuardPublicKey, IPEndpoint)
    case sendFailed(WireGuardPublicKey?, errno: Int32)
    case socketsRebound(port: UInt16)
    case rebindFailed(attempt: Int, errno: Int32, final: Bool)
    case packetsDropped(DropReason, count: Int)
}

/// Manages asynchronous event delivery, send-failure rate limiting, and drop coalescing.
/// Uses leaf locks that never acquire `WireGuardDevice.lock` so subscribers can freely
/// re-enter the device (e.g. `status()`, `initiateHandshake(for:)`) without deadlocking.
final class DeviceEventDispatcher: @unchecked Sendable {
    private struct SendFailureKey: Hashable {
        let peer: WireGuardPublicKey?
        let errno: Int32
    }

    private let handlerLock = NSLock()
    private var handler: (@Sendable (DeviceEvent) -> Void)?
    private let queue = DispatchQueue(label: "WireGuardEngine.events", qos: .utility)

    private let stateLock = NSLock()
    private var lastSendFailure: [SendFailureKey: ProtocolInstant] = [:]
    private var pendingDrops: [DropReason: Int] = [:]
    private var nextDropFlushAt: ProtocolInstant?
    private var dropTimerScheduled = false

    var onEvent: (@Sendable (DeviceEvent) -> Void)? {
        get { handlerLock.withLock { handler } }
        set { handlerLock.withLock { handler = newValue } }
    }

    func emit(_ event: DeviceEvent) {
        let currentHandler = handlerLock.withLock { handler }
        guard let currentHandler else { return }
        queue.async {
            currentHandler(event)
        }
    }

    func drain() {
        queue.sync {}
    }

    func recordSendFailure(peer: WireGuardPublicKey?, error: Error, now: ProtocolInstant) {
        let code = Self.posixErrno(from: error)
        let key = SendFailureKey(peer: peer, errno: code)
        let shouldEmit: Bool = stateLock.withLock {
            if let previous = lastSendFailure[key], now.elapsed(since: previous) < ProtocolInstant.second {
                return false
            }
            if lastSendFailure.count > 256 {
                lastSendFailure = lastSendFailure.filter { now.elapsed(since: $0.value) < ProtocolInstant.second }
            }
            lastSendFailure[key] = now
            return true
        }
        if shouldEmit {
            emit(.sendFailed(peer, errno: code))
        }
    }

    /// Accumulates dropped packet counts and returns the flush deadline if a flush timer
    /// needs to be scheduled for this coalescing window.
    func recordDrop(_ reason: DropReason, count: Int, now: ProtocolInstant) -> ProtocolInstant? {
        guard count > 0 else { return nil }
        return stateLock.withLock {
            pendingDrops[reason, default: 0] += count
            if nextDropFlushAt == nil {
                nextDropFlushAt = now.advanced(by: ProtocolInstant.second)
            }
            guard !dropTimerScheduled else { return nil }
            dropTimerScheduled = true
            return nextDropFlushAt
        }
    }

    var currentDropFlushDeadline: ProtocolInstant? {
        stateLock.withLock { nextDropFlushAt }
    }

    func hasDueDrops(at now: ProtocolInstant) -> Bool {
        stateLock.withLock {
            guard !pendingDrops.isEmpty, let flushAt = nextDropFlushAt else { return false }
            return now >= flushAt
        }
    }

    func flushDrops(at now: ProtocolInstant, force: Bool) {
        let drained: [(DropReason, Int)] = stateLock.withLock {
            guard !pendingDrops.isEmpty else {
                if force {
                    nextDropFlushAt = nil
                    dropTimerScheduled = false
                }
                return []
            }
            if !force, let flushAt = nextDropFlushAt, now < flushAt {
                return []
            }
            let items = pendingDrops.sorted { $0.key.rawValue < $1.key.rawValue }
            pendingDrops.removeAll(keepingCapacity: true)
            nextDropFlushAt = nil
            dropTimerScheduled = false
            return items
        }
        for (reason, count) in drained where count > 0 {
            emit(.packetsDropped(reason, count: count))
        }
    }

    static func posixErrno(from error: Error) -> Int32 {
        if let posix = error as? POSIXError {
            return posix.code.rawValue
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code > 0 {
            return Int32(clamping: nsError.code)
        }
        return EIO
    }
}

extension WireGuardDevice {
    /// Subscriber notified asynchronously on a dedicated serial queue (`WireGuardEngine.events`).
    /// Never called while holding internal device locks.
    public var onEvent: (@Sendable (DeviceEvent) -> Void)? {
        get { events.onEvent }
        set { events.onEvent = newValue }
    }

    func emitEvent(_ event: DeviceEvent) {
        events.emit(event)
    }

    func drainEvents() {
        events.drain()
    }

    func recordSendFailure(peer: WireGuardPublicKey?, error: Error) {
        events.recordSendFailure(peer: peer, error: error, now: protocolNow())
    }

    func recordDrop(_ reason: DropReason, count: Int = 1) {
        guard events.recordDrop(reason, count: count, now: protocolNow()) != nil,
              let io else { return }
        if io.onHandshakeQueue {
            lock.withLock {
                guard io.state != .closed else { return }
                let target = events.currentDropFlushDeadline
                io.deadlines.update(peer: nil, kind: .flushDrops, time: target)
                armNextDeadline(io)
            }
        } else {
            io.handshake.queue.async { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    guard let io = self.io, io.state != .closed else { return }
                    let target = self.events.currentDropFlushDeadline
                    io.deadlines.update(peer: nil, kind: .flushDrops, time: target)
                    self.armNextDeadline(io)
                }
            }
        }
    }

    func flushPendingDrops(force: Bool) {
        events.flushDrops(at: protocolNow(), force: force)
    }
}
