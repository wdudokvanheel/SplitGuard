// SPDX-License-Identifier: MIT

import Foundation

public enum PauseReason: String, Codable, Sendable, Equatable {
    case offline
    case user
    case system
}

public enum DeviceState: Codable, Sendable, Equatable {
    case down
    case up
    case paused(PauseReason)
}

public enum PeerHealth: String, Codable, Sendable, Equatable {
    case connecting
    case noHandshake
    case stalled
    case idle
    case healthy
}

public struct PeerStatus: Codable, Sendable, Equatable {
    public var publicKey: WireGuardPublicKey
    public var endpoint: IPEndpoint?
    public var health: PeerHealth
    public var lastHandshake: Date?
    public var handshakeRoundTrip: Duration?
    public var handshakeAttempts: Int
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public var lastReceived: Date?
    public var lastSent: Date?

    public init(
        publicKey: WireGuardPublicKey,
        endpoint: IPEndpoint?,
        health: PeerHealth,
        lastHandshake: Date?,
        handshakeRoundTrip: Duration?,
        handshakeAttempts: Int,
        rxBytes: UInt64,
        txBytes: UInt64,
        lastReceived: Date?,
        lastSent: Date?
    ) {
        self.publicKey = publicKey
        self.endpoint = endpoint
        self.health = health
        self.lastHandshake = lastHandshake
        self.handshakeRoundTrip = handshakeRoundTrip
        self.handshakeAttempts = handshakeAttempts
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.lastReceived = lastReceived
        self.lastSent = lastSent
    }
}

public struct DeviceStatus: Codable, Sendable, Equatable {
    public var state: DeviceState
    public var listenPort: UInt16
    public var peers: [PeerStatus]

    public init(state: DeviceState, listenPort: UInt16, peers: [PeerStatus]) {
        self.state = state
        self.listenPort = listenPort
        self.peers = peers
    }
}

extension WireGuardDevice {
    /// Returns a typed, secret-free snapshot of the device and all configured peers.
    public func status() -> DeviceStatus {
        lock.withLock {
            let deviceUp = io?.state == .up
            let deviceState: DeviceState = deviceUp ? .up : .down
            let activePort = io == nil ? configuredPort : boundPort
            let now = protocolNow()
            let orderedPeers = peers.values.sorted {
                $0.publicKey.rawValue.lexicographicallyPrecedes($1.publicKey.rawValue)
            }
            let peerStatuses = orderedPeers.map { peer in
                peer.withState { state in
                    PeerStatus(
                        publicKey: peer.publicKey,
                        endpoint: state.endpoint,
                        health: Self.computePeerHealth(for: state, deviceUp: deviceUp, now: now),
                        lastHandshake: Self.dateFromUnixNanoseconds(
                            state.lastHandshakeUnixNanoseconds > 0 ? state.lastHandshakeUnixNanoseconds : nil
                        ),
                        handshakeRoundTrip: state.handshakeRoundTripNanoseconds.map {
                            Duration.nanoseconds(Int64(clamping: $0))
                        },
                        handshakeAttempts: state.handshakeAttempts,
                        rxBytes: state.rxBytes,
                        txBytes: state.txBytes,
                        lastReceived: Self.dateFromUnixNanoseconds(state.lastReceivedUnixNanoseconds),
                        lastSent: Self.dateFromUnixNanoseconds(state.lastSentUnixNanoseconds)
                    )
                }
            }
            return DeviceStatus(state: deviceState, listenPort: activePort, peers: peerStatuses)
        }
    }

    /// Forces an immediate fresh handshake initiation for the given peer when the device is up.
    public func initiateHandshake(for publicKey: WireGuardPublicKey) {
        lock.withLock {
            guard let io, io.state == .up, let peer = peers[publicKey] else { return }
            let running = peer.withState { state -> Bool in
                guard state.running else { return false }
                state.lastSentHandshake = nil
                state.handshakeAttempts = 0
                state.handshakeGaveUp = false
                state.handshakeInitiatedAt = nil
                return true
            }
            guard running else { return }
            if io.onHandshakeQueue {
                sendHandshakeInitiation(peer, retry: false, io: io)
            } else {
                timer(.initiate, for: peer, after: 0, io: io)
                io.manualWakeHandshake()
            }
        }
    }

    static func computePeerHealth(
        for state: WireGuardPeer.State,
        deviceUp: Bool,
        now: ProtocolInstant
    ) -> PeerHealth {
        guard deviceUp, state.running else { return .idle }
        let unansweredThreshold = WireGuardTiming.keepaliveTimeout + WireGuardTiming.rekeyTimeout
        guard let lastHS = state.lastHandshakeInstant else {
            if state.handshakeGaveUp {
                return .noHandshake
            }
            if let initiatedAt = state.handshakeInitiatedAt {
                if now.elapsed(since: initiatedAt) >= unansweredThreshold {
                    return .noHandshake
                }
                return .connecting
            }
            return .idle
        }
        let hsAge = now.elapsed(since: lastHS)
        let unansweredData: Bool = state.lastDataSentInstant.map { sent in
            let afterLastReceive = state.lastAuthenticatedReceivedInstant.map { sent >= $0 } ?? true
            return afterLastReceive && (
                now.elapsed(since: sent) >= unansweredThreshold
                    || state.handshakeGaveUp
                    || hsAge >= WireGuardTiming.rejectAfterTime
            )
        } ?? false
        if unansweredData {
            return .stalled
        }
        if hsAge >= WireGuardTiming.rejectAfterTime {
            return .idle
        }
        return .healthy
    }

    static func nextHealthCheckDeadline(
        for state: WireGuardPeer.State,
        currentHealth: PeerHealth,
        deviceUp: Bool,
        now: ProtocolInstant
    ) -> ProtocolInstant? {
        guard deviceUp, state.running else { return nil }
        let unansweredThreshold = WireGuardTiming.keepaliveTimeout + WireGuardTiming.rekeyTimeout
        switch currentHealth {
        case .connecting:
            guard let initiatedAt = state.handshakeInitiatedAt else { return nil }
            let deadline = initiatedAt.advanced(by: unansweredThreshold)
            return deadline > now ? deadline : nil
        case .healthy:
            guard let lastHS = state.lastHandshakeInstant else { return nil }
            var earliest = lastHS.advanced(by: WireGuardTiming.rejectAfterTime)
            if let sent = state.lastDataSentInstant,
               state.lastAuthenticatedReceivedInstant.map({ sent >= $0 }) ?? true {
                let stalledAt = sent.advanced(by: unansweredThreshold)
                if stalledAt < earliest {
                    earliest = stalledAt
                }
            }
            return earliest > now ? earliest : nil
        case .noHandshake, .stalled, .idle:
            return nil
        }
    }

    func updatePeerHealth(_ peer: WireGuardPeer, io: DeviceIO, now: ProtocolInstant? = nil) {
        let now = now ?? protocolNow()
        let deviceUp = io.state == .up
        let (transition, nextCheck): (PeerHealth?, ProtocolInstant?) = peer.withState { state in
            let computed = Self.computePeerHealth(for: state, deviceUp: deviceUp, now: now)
            let changed: PeerHealth? = computed != state.lastReportedHealth ? computed : nil
            if let changed {
                state.lastReportedHealth = changed
            }
            let next = Self.nextHealthCheckDeadline(
                for: state,
                currentHealth: computed,
                deviceUp: deviceUp,
                now: now
            )
            return (changed, next)
        }
        if io.state != .closed {
            io.deadlines.update(peer: peer, kind: .healthCheck, time: nextCheck)
            armNextDeadline(io)
        }
        if let transition {
            emitEvent(.healthChanged(peer.publicKey, transition))
        }
    }

    private static func dateFromUnixNanoseconds(_ nanoseconds: Int64?) -> Date? {
        guard let nanoseconds else { return nil }
        return Date(timeIntervalSince1970: Double(nanoseconds) / Double(ProtocolInstant.second))
    }
}
