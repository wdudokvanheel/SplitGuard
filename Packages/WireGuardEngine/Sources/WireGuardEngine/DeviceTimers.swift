// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Dispatch

extension WireGuardDevice {
    /// Refresh the one-shot alarm after an externally observed wake or path change.
    /// The system timer normally observes sleep itself. Protocol decisions always
    /// compare the original deadline with the sleep-inclusive clock.
    public func reevaluateDeadlines() {
        lock.withLock {
            guard let io, io.state != .closed else { return }
            io.armedDeadline = nil
            armNextDeadline(io)
        }
    }

    func armNextDeadline(_ io: DeviceIO) {
        guard let next = io.deadlines.first?.time else {
            guard io.armedDeadline != nil else { return }
            io.armedDeadline = nil
            io.scheduler.arm(after: nil)
            return
        }
        if let armed = io.armedDeadline, armed <= next { return }
        io.armedDeadline = next
        io.scheduler.arm(after: next.elapsed(since: protocolNow()))
    }

    func timer(_ kind: PeerTimer, for peer: WireGuardPeer?, after delay: UInt64?, io: DeviceIO) {
        io.deadlines.update(peer: peer, kind: kind, time: delay.map { protocolNow().advanced(by: $0) })
        armNextDeadline(io)
    }

    private func jitter(_ io: DeviceIO) -> UInt64 {
        min(io.jitterMilliseconds(), 333) * 1_000_000
    }

    func timerPending(_ kind: PeerTimer, _ peer: WireGuardPeer?, io: DeviceIO) -> Bool {
        io.deadlines.contains(PeerTimerKey(peer, kind))
    }

    /// Runs on the handshake lane. Manual tests advance their clock then drive this entry point.
    func processDeadlines() {
        lock.withLock {
            guard let io, io.state != .closed else { return }
            io.scheduler.consume()
            io.armedDeadline = nil
            for _ in 0..<64 {
                guard let next = io.deadlines.first, next.time <= protocolNow() else { break }
                io.deadlines.update(peer: next.peer, kind: next.key.kind, time: nil)
                if let peer = next.peer, canRun(peer, io: io) {
                    expire(next.key.kind, for: peer, io: io)
                } else if next.key.kind == .collectRateLimiter, !io.limiter.collectStaleEntries() {
                    timer(.collectRateLimiter, for: nil, after: HandshakeRateLimiter.collectionInterval, io: io)
                }
            }
            armNextDeadline(io)
        }
    }

    private func expire(_ kind: PeerTimer, for peer: WireGuardPeer, io: DeviceIO) {
        switch kind {
        case .retransmitHandshake:
            let retry = peer.withState { state -> Bool in
                guard state.handshakeAttempts <= WireGuardTiming.maxTimerHandshakes else { return false }
                state.handshakeAttempts += 1
                return true
            }
            if retry {
                clearEndpointSource(peer, io: io)
                sendHandshakeInitiation(peer, retry: true, io: io)
            } else {
                timer(.sendKeepalive, for: peer, after: nil, io: io)
                flushStaged(peer)
                if !timerPending(.zeroKeyMaterial, peer, io: io) {
                    timer(.zeroKeyMaterial, for: peer, after: WireGuardTiming.zeroAfterTime, io: io)
                }
            }
        case .sendKeepalive:
            sendKeepalive(peer)
            let again = peer.withState {
                let again = $0.needAnotherKeepalive
                $0.needAnotherKeepalive = false
                return again
            }
            if again { timer(.sendKeepalive, for: peer, after: WireGuardTiming.keepaliveTimeout, io: io) }
        case .newHandshake:
            clearEndpointSource(peer, io: io)
            sendHandshakeInitiation(peer, retry: false, io: io)
        case .zeroKeyMaterial:
            zeroAndFlush(peer)
        case .persistentKeepalive:
            if peer.withState({ $0.persistentKeepaliveInterval > 0 }) { sendKeepalive(peer) }
        case .initiate:
            sendHandshakeInitiation(peer, retry: false, io: io)
        case .collectRateLimiter:
            break
        }
    }

    func rateLimitAllows(_ source: IPEndpoint, io: DeviceIO) -> Bool {
        let allowed = io.limiter.allow(source.address)
        if !timerPending(.collectRateLimiter, nil, io: io) {
            timer(.collectRateLimiter, for: nil, after: HandshakeRateLimiter.collectionInterval, io: io)
        }
        return allowed
    }

    func timerDataSent(_ peer: WireGuardPeer, io: DeviceIO) {
        if !timerPending(.newHandshake, peer, io: io) {
            timer(.newHandshake, for: peer,
                  after: WireGuardTiming.keepaliveTimeout + WireGuardTiming.rekeyTimeout + jitter(io), io: io)
        }
    }

    func timerDataReceived(_ peer: WireGuardPeer, io: DeviceIO) {
        if timerPending(.sendKeepalive, peer, io: io) {
            peer.withState { $0.needAnotherKeepalive = true }
        } else {
            timer(.sendKeepalive, for: peer, after: WireGuardTiming.keepaliveTimeout, io: io)
        }
    }

    func timerAuthenticatedSent(_ peer: WireGuardPeer, io: DeviceIO) {
        timer(.sendKeepalive, for: peer, after: nil, io: io)
    }

    func timerAuthenticatedReceived(_ peer: WireGuardPeer, io: DeviceIO) {
        timer(.newHandshake, for: peer, after: nil, io: io)
    }

    func timerHandshakeComplete(_ peer: WireGuardPeer, io: DeviceIO) {
        timer(.retransmitHandshake, for: peer, after: nil, io: io)
        timer(.initiate, for: peer, after: nil, io: io)
        peer.withState {
            $0.handshakeAttempts = 0
            $0.sentLastMinuteHandshake = false
            $0.lastHandshakeUnixNanoseconds = io.wallNow()
        }
    }

    func timerSessionDerived(_ peer: WireGuardPeer, io: DeviceIO) {
        timer(.zeroKeyMaterial, for: peer, after: WireGuardTiming.zeroAfterTime, io: io)
    }

    func timerAuthenticatedTraversal(_ peer: WireGuardPeer, interval: UInt16, io: DeviceIO) {
        if interval > 0 {
            timer(.persistentKeepalive, for: peer, after: UInt64(interval) * ProtocolInstant.second, io: io)
        }
    }

    func timerAuthenticatedTraversal(_ peer: WireGuardPeer, io: DeviceIO) {
        let interval = peer.withState { $0.persistentKeepaliveInterval }
        timerAuthenticatedTraversal(peer, interval: interval, io: io)
    }

    func requestHandshakeInitiation(_ peer: WireGuardPeer, io: DeviceIO) {
        if io.onHandshakeQueue {
            sendHandshakeInitiation(peer, retry: false, io: io)
            return
        }
        if mayInitiate(peer, retry: false), !timerPending(.initiate, peer, io: io) {
            timer(.initiate, for: peer, after: 0, io: io)
            io.manualWakeHandshake()
        }
    }

    private func mayInitiate(_ peer: WireGuardPeer, retry: Bool) -> Bool {
        let now = protocolNow()
        return peer.withState { state in
            if !retry { state.handshakeAttempts = 0 }
            return state.lastSentHandshake.map { now.elapsed(since: $0) >= WireGuardTiming.rekeyTimeout } ?? true
        }
    }

    func sendHandshakeInitiation(_ peer: WireGuardPeer, retry: Bool, io: DeviceIO) {
        let now = protocolNow()
        let allowed = peer.withState { state -> Bool in
            if !retry { state.handshakeAttempts = 0 }
            guard state.lastSentHandshake.map({ now.elapsed(since: $0) >= WireGuardTiming.rekeyTimeout }) ?? true else {
                return false
            }
            state.lastSentHandshake = now
            return true
        }
        guard allowed else { return }
        guard let packet = try? createHandshakeInitiation(for: peer) else { return }
        timerAuthenticatedTraversal(peer, io: io)
        timerAuthenticatedSent(peer, io: io)
        sendWire(packet.bytes, to: peer, io: io)
        timer(.retransmitHandshake, for: peer, after: WireGuardTiming.rekeyTimeout + jitter(io), io: io)
    }

    func sendHandshakeResponse(_ peer: WireGuardPeer, io: DeviceIO) {
        peer.withState { $0.lastSentHandshake = protocolNow() }
        guard let (packet, _) = try? createHandshakeResponse(for: peer) else { return }
        if canRun(peer, io: io) {
            timerSessionDerived(peer, io: io)
            timerAuthenticatedTraversal(peer, io: io)
            timerAuthenticatedSent(peer, io: io)
        }
        sendWire(packet.bytes, to: peer, io: io)
    }
}
