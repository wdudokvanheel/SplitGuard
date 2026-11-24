// SPDX-License-Identifier: MIT

import Darwin
import Dispatch
import Foundation

final class DeviceIO: @unchecked Sendable {
    enum State: Sendable {
        case down, up, closed
    }

    struct FromTunnel: Sendable {
        let data: Data
        let run: UInt64
    }

    struct FromWire: Sendable {
        let data: Data
        let source: IPEndpoint
        let run: UInt64
    }

    struct EncryptedTransport: Sendable {
        let wire: FromWire
        let header: TransportHeader
        let peer: WireGuardPeer
        let keypair: SessionKeypair
    }

    static let outboundHighWaterMark = 512
    static let outboundLowWaterMark = 256

    let tunnel: TunnelDevice
    let transport: UDPTransport
    let outbound = PacketLane<FromTunnel>("outbound", capacity: 1024)
    let inbound = PacketLane<EncryptedTransport>("inbound", capacity: 1024)
    let handshake = PacketLane<FromWire>("handshake", capacity: 1024)
    let outboundReady: DispatchSourceUserDataAdd
    let scheduler: DeadlineScheduler
    private let handshakeQueueKey = DispatchSpecificKey<UInt8>()
    var onHandshakeQueue: Bool { DispatchQueue.getSpecific(key: handshakeQueueKey) != nil }

    // Used exclusively on the outbound lane.
    var paddingScratch = Data(capacity: WireGuardDevice.maxContentSize)
    let wallNow: () -> Int64
    let jitterMilliseconds: () -> UInt64
    let limiter: HandshakeRateLimiter

    // The fields below are protected by the device lock.
    var state = State.down
    var run: UInt64 = 0
    var bindGeneration: UInt64 = 0
    var brokenRoaming = false
    var readyPeers = ReadyPeers()
    var stagedCount = 0
    var stagedPeak = 0
    var peerStagedPeak = 0
    var stagedDrops = 0
    var deadlines = ProtocolDeadlines()
    var armedDeadline: ProtocolInstant?
    var underLoadUntil: ProtocolInstant?

    init(
        tunnel: TunnelDevice, transport: UDPTransport,
        now: @escaping () -> ProtocolInstant = ProtocolInstant.now,
        wallNow: @escaping () -> Int64 = DeviceIO.unixNanoseconds,
        jitterMilliseconds: @escaping () -> UInt64 = { UInt64.random(in: 0..<334) },
        automaticTimers: Bool = true
    ) throws {
        self.tunnel = tunnel
        self.transport = transport
        self.wallNow = wallNow
        self.jitterMilliseconds = jitterMilliseconds
        limiter = HandshakeRateLimiter(now: now, maximumEntries: 4096)
        handshake.queue.setSpecific(key: handshakeQueueKey, value: 1)
        if automaticTimers {
            scheduler = try ContinuousAlarmScheduler(queue: handshake.queue)
        } else {
            scheduler = ManualDeadlineScheduler(queue: handshake.queue)
        }
        outboundReady = DispatchSource.makeUserDataAddSource(queue: outbound.queue)
        outboundReady.resume()
    }

    func install(on device: WireGuardDevice) {
        outbound.configureBackpressure(
            highWaterMark: Self.outboundHighWaterMark,
            lowWaterMark: Self.outboundLowWaterMark,
            onHighWater: { [weak self] in self?.tunnel.pauseReading() },
            onLowWater: { [weak self] in self?.tunnel.resumeReading() }
        )
        outbound.install { [weak device] in device?.stageTunnelPacket($0) }
        outboundReady.setEventHandler { [weak device] in device?.drainReadyPeers() }
        inbound.installBatch { [weak device] in device?.decryptTransportBatch($0) }
        handshake.install { [weak device] in device?.handleHandshake($0) }
        scheduler.install { [weak device] in device?.processDeadlines() }
    }

    func manualWakeHandshake() {
        scheduler.wakeNow()
    }

    func withHandshakeLane<Result>(_ body: () throws -> Result) rethrows -> Result {
        if onHandshakeQueue { return try body() }
        return try handshake.queue.sync(execute: body)
    }

    private static func unixNanoseconds() -> Int64 {
        var instant = timespec()
        clock_gettime(CLOCK_REALTIME, &instant)
        return Int64(instant.tv_sec) * Int64(ProtocolInstant.second) + Int64(instant.tv_nsec)
    }
}

extension WireGuardDevice {
    public static let maxSegmentSize = 1700
    public static let maxContentSize = maxSegmentSize - TransportHeader.minimumPacketSize
    static let stagedCapacity = 128
    static let stagedBufferLimit = 1024

    /// Start a new read registration and bind UDP using the configured port. A failed
    /// start returns the device to down. Configuration can be applied before or after up.
    public func up() throws {
        guard let io else { return }
        try io.withHandshakeLane { try startLocked() }
    }

    private func startLocked() throws {
        try lock.withLock {
            guard let io, io.state == .down else { return }
            io.state = .up
            io.run &+= 1
            let run = io.run
            do {
                try rebindLocked(io)
                io.outbound.register(run)
                try io.tunnel.start { [weak self, weak io] data in
                    guard let io else { return false }
                    guard (1...Self.maxContentSize).contains(data.count) else {
                        self?.recordDrop(.invalidPacket)
                        return false
                    }
                    switch io.outbound.offerResult(.init(data: data, run: run), token: run) {
                    case .admitted:
                        return true
                    case .queueFull:
                        self?.recordDrop(.queueFull)
                        return false
                    case .staleToken:
                        return false
                    }
                }
            } catch {
                _ = try? stopLocked(io, finalState: .down, emitStateChange: false)
                throw error
            }
            emitEvent(.stateChanged(.up))
            for peer in peers.values {
                startPeer(peer)
                if peer.withState({ $0.persistentKeepaliveInterval > 0 }) {
                    sendKeepalive(peer)
                }
            }
        }
    }

    /// Stop dispatching packets and retire all sessions. Static configuration and
    /// statistics persist. An adapter may still call an old receive closure after down.
    public func down() throws {
        try lock.withLock {
            guard let io, io.state == .up else { return }
            try stopLocked(io, finalState: .down, emitStateChange: true)
        }
    }

    /// Permanently release the adapters and remove the device's peers.
    public func close() {
        lock.withLock {
            if let io {
                guard io.state != .closed else { return }
                if io.state == .up {
                    _ = try? stopLocked(io, finalState: .closed, emitStateChange: true)
                } else {
                    io.state = .closed
                    flushPendingDrops(force: true)
                }
                io.tunnel.close()
                io.deadlines.update(peer: nil, kind: .collectRateLimiter, time: nil)
                io.deadlines.update(peer: nil, kind: .flushDrops, time: nil)
                armNextDeadline(io)
                io.limiter.reset()
            }
            for key in Array(peers.keys) { removePeer(key) }
            io?.scheduler.cancel()
        }
    }

    private func stopLocked(_ io: DeviceIO, finalState: DeviceIO.State, emitStateChange: Bool) throws {
        io.state = finalState
        io.outbound.register(nil, discard: true)
        io.inbound.register(nil, discard: true)
        io.handshake.register(nil, discard: true)
        io.tunnel.stop()
        defer {
            io.deadlines.update(peer: nil, kind: .flushDrops, time: nil)
            flushPendingDrops(force: true)
            for peer in peers.values { stopPeer(peer) }
            // The limiter is device-wide and can finish collecting after down.
            armNextDeadline(io)
            if emitStateChange {
                emitEvent(.stateChanged(.down))
            }
        }
        boundPort = 0
        try io.transport.unbind()
    }

    /// Replace the UDP socket registrations while preserving the device's current sessions.
    public func rebind(attempt: Int = 1, final: Bool = false) throws {
        try lock.withLock {
            guard let io, io.state == .up else { return }
            try rebindLocked(io, attempt: attempt, final: final)
        }
    }

    func rebindLocked(_ io: DeviceIO, attempt: Int = 1, final: Bool = false) throws {
        guard io.state != .closed else { return }
        io.inbound.register(nil)
        io.handshake.register(nil)
        boundPort = 0
        try io.transport.unbind()
        guard io.state == .up else { return }
        io.bindGeneration &+= 1
        let generation = io.bindGeneration
        let run = io.run
        io.inbound.register(generation)
        io.handshake.register(generation)
        do {
            boundPort = try io.transport.bind(port: configuredPort) { [weak self] data, source in
                self?.admitDatagram(.init(data: data, source: source, run: run), generation: generation) ?? false
            }
            if mark != 0 { try io.transport.setFirewallMark(mark) }
        } catch {
            if boundPort != 0 {
                _ = try? io.transport.unbind()
            }
            boundPort = 0
            io.inbound.register(nil)
            io.handshake.register(nil)
            emitEvent(.rebindFailed(attempt: attempt, errno: DeviceEventDispatcher.posixErrno(from: error), final: final))
            throw error
        }
        clearEndpointSources(io)
        emitEvent(.socketsRebound(port: boundPort))
    }

    func clearEndpointSources(_ io: DeviceIO) {
        for peer in peers.values { clearEndpointSource(peer, io: io) }
    }

    func clearEndpointSource(_ peer: WireGuardPeer, io: DeviceIO) {
        if let endpoint = peer.withState({ $0.endpoint }) { io.transport.clearSource(for: endpoint) }
    }

    /// Match the mobile bind: peers with a configured endpoint keep it, while peers
    /// with no endpoint can learn one from an authenticated datagram.
    public func disableSomeRoamingForBrokenMobileSemantics() {
        lock.withLock {
            guard let io else { return }
            io.brokenRoaming = true
            for peer in peers.values {
                peer.withState { $0.roamingDisabled = $0.endpoint != nil }
            }
        }
    }

    /// Used after a successful path rebind to prompt peers with current keys.
    public func sendKeepalivesToPeersWithCurrentKeypair() {
        lock.withLock {
            guard io?.state == .up else { return }
            let now = protocolNow()
            for peer in peers.values {
                if let current = peer.keypairs.current,
                   now.elapsed(since: current.created) <= WireGuardTiming.rejectAfterTime {
                    sendKeepalive(peer)
                }
            }
        }
    }

    func startPeer(_ peer: WireGuardPeer) {
        peer.withState {
            guard !$0.running else { return }
            $0.running = true
            $0.lastSentHandshake = nil
            $0.handshakeInitiatedAt = nil
            $0.lastInitiationSentAt = nil
            $0.handshakeGaveUp = false
            $0.handshakeAttempts = 0
            $0.needAnotherKeepalive = false
            $0.sentLastMinuteHandshake = false
        }
    }

    func stopPeer(_ peer: WireGuardPeer) {
        let healthChangedToIdle = peer.withState { state -> Bool in
            state.running = false
            state.handshakeInitiatedAt = nil
            state.lastInitiationSentAt = nil
            state.handshakeGaveUp = false
            state.lastHandshakeInstant = nil
            state.lastAuthenticatedReceivedInstant = nil
            state.lastDataSentInstant = nil
            if state.lastReportedHealth != .idle {
                state.lastReportedHealth = .idle
                return true
            }
            return false
        }
        if let io {
            for kind in PeerTimer.allCases { io.deadlines.update(peer: peer, kind: kind, time: nil) }
            armNextDeadline(io)
        }
        zeroAndFlush(peer)
        if healthChangedToIdle {
            emitEvent(.healthChanged(peer.publicKey, .idle))
        }
    }

    func zeroAndFlush(_ peer: WireGuardPeer, dropReason: DropReason? = nil) {
        peer.withState { state in
            clearHandshake(&state.handshake, for: peer)
            peer.keypairs.withSlots { slots in
                for keypair in [slots.previous, slots.current, slots.next].compactMap({ $0 }) {
                    indices.delete(keypair)
                    keypair.expireSending()
                }
                slots = SessionKeypairs.Slots()
            }
        }
        flushStaged(peer, dropReason: dropReason)
    }

    func canRun(_ peer: WireGuardPeer, io: DeviceIO) -> Bool {
        io.state == .up && peers[peer.publicKey] === peer && peer.withState { $0.running }
    }

    func roam(_ peer: WireGuardPeer, from source: IPEndpoint) {
        let changed = peer.withState { $0.roam(to: source) }
        if changed {
            emitEvent(.endpointChanged(peer.publicKey, source))
        }
    }

    func accountReceived(_ peer: WireGuardPeer, bytes: Int) {
        peer.withState { $0.rxBytes &+= UInt64(bytes) }
    }

    @discardableResult
    func sendWire(_ packet: Data, to peer: WireGuardPeer, io: DeviceIO) -> Bool {
        guard let endpoint = peer.withState({ $0.endpoint }) else { return false }
        do {
            try io.transport.send(packet, to: endpoint)
            let wallNow = io.wallNow()
            peer.withState {
                $0.txBytes &+= UInt64(packet.count)
                $0.lastSentUnixNanoseconds = wallNow
            }
            return true
        } catch {
            recordSendFailure(peer: peer.publicKey, error: error)
            return false
        }
    }
}
