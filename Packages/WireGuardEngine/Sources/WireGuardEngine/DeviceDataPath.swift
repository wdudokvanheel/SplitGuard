// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import CryptoKit
import Foundation

private struct StagedTransport {
    let peer: WireGuardPeer
    let session: SessionKeypair
    let counter: UInt64
    let packet: Data
    let run: UInt64
}

extension WireGuardDevice {
    func stageTunnelPacket(_ incoming: DeviceIO.FromTunnel) {
        guard let route = IPPacket(incoming.data, inbound: false) else { return }
        lock.withLock {
            guard let io, io.state == .up, incoming.run == io.run,
                  let peer = allowedIPs.lookup(route.address),
                  peers[peer.publicKey] === peer else { return }
            if stage(incoming.data, for: peer, io: io, requireRunning: true) {
                scheduleStagedDrain(peer, io: io, wake: true)
            }
        }
    }

    /// Stages a packet for `peer`. Returns true if the peer has at least one staged packet ready to drain.
    @discardableResult
    private func stage(_ packet: Data, for peer: WireGuardPeer, io: DeviceIO, requireRunning: Bool = false) -> Bool {
        enum StageOutcome {
            case skipped
            case staged
            case needsGlobalEviction
        }
        let outcome: StageOutcome = peer.withState { state in
            if requireRunning, !state.running { return .skipped }
            if state.staged.count == Self.stagedCapacity {
                _ = state.staged.popFirst()
                io.stagedCount -= 1
                io.stagedDrops += 1
            }
            if io.stagedCount >= Self.stagedBufferLimit {
                return .needsGlobalEviction
            }
            if state.staged.append(packet) {
                io.stagedCount += 1
                io.stagedPeak = max(io.stagedPeak, io.stagedCount)
                io.peerStagedPeak = max(io.peerStagedPeak, state.staged.count)
                return .staged
            }
            io.stagedDrops += 1
            return state.staged.count > 0 ? .staged : .skipped
        }
        switch outcome {
        case .skipped:
            return false
        case .staged:
            return true
        case .needsGlobalEviction:
            evictLongestStagedPeer(excluding: peer, io: io)
            return peer.withState { state in
                guard io.stagedCount < Self.stagedBufferLimit, state.staged.append(packet) else {
                    io.stagedDrops += 1
                    return state.staged.count > 0
                }
                io.stagedCount += 1
                io.stagedPeak = max(io.stagedPeak, io.stagedCount)
                io.peerStagedPeak = max(io.peerStagedPeak, state.staged.count)
                return true
            }
        }
    }

    private func evictLongestStagedPeer(excluding current: WireGuardPeer, io: DeviceIO) {
        var victim: WireGuardPeer?
        var longest = 0
        for candidate in peers.values where candidate !== current {
            let count = candidate.withState { $0.staged.count }
            if count > longest {
                victim = candidate
                longest = count
            }
        }
        guard let victim else { return }
        let emptied = victim.withState { state -> Bool in
            guard state.staged.popFirst() != nil else { return false }
            io.stagedCount -= 1
            io.stagedDrops += 1
            return state.staged.count == 0
        }
        if emptied {
            io.readyPeers.remove(victim)
        }
    }

    func flushStaged(_ peer: WireGuardPeer) {
        guard let io else { return }
        io.readyPeers.remove(peer)
        peer.withState {
            io.stagedCount -= $0.staged.count
            io.stagedDrops += $0.staged.count
            $0.staged.removeAll()
        }
    }

    func sendKeepalive(_ peer: WireGuardPeer) {
        guard let io, io.state == .up, peers[peer.publicKey] === peer else { return }
        enum KeepaliveOutcome { case skipped, ready, needsStage }
        let outcome: KeepaliveOutcome = peer.withState { state in
            guard state.running else { return .skipped }
            return state.staged.count == 0 ? .needsStage : .ready
        }
        switch outcome {
        case .skipped:
            return
        case .needsStage:
            if stage(Data(), for: peer, io: io) {
                scheduleStagedDrain(peer, io: io, wake: true)
            }
        case .ready:
            scheduleStagedDrain(peer, io: io, wake: true)
        }
    }

    private func usableSendingSession(_ peer: WireGuardPeer) -> SessionKeypair? {
        guard let keypair = peer.keypairs.current,
              keypair.nextSendCounter < ReplayFilter.rejectAfterMessages,
              protocolNow().elapsed(since: keypair.created) < WireGuardTiming.rejectAfterTime else { return nil }
        return keypair
    }

    func requestStagedDrain(_ peer: WireGuardPeer, wake: Bool = true) {
        guard let io, io.state == .up, peers[peer.publicKey] === peer,
              peer.withState({ $0.running && $0.staged.count > 0 }) else { return }
        scheduleStagedDrain(peer, io: io, wake: wake)
    }

    private func scheduleStagedDrain(_ peer: WireGuardPeer, io: DeviceIO, wake: Bool) {
        if usableSendingSession(peer) != nil {
            let wasIdle = io.readyPeers.isEmpty
            io.readyPeers.append(peer)
            if wake && wasIdle { io.outboundReady.add(data: 1) }
        } else {
            requestHandshakeInitiation(peer, io: io)
        }
    }

    private func takeStaged(_ io: DeviceIO) -> StagedTransport? {
        guard io.state == .up else { return nil }
        while let peer = io.readyPeers.popFirst() {
            guard peers[peer.publicKey] === peer else { continue }
            enum TakeAction {
                case skip
                case initiate
                case send(SessionKeypair, UInt64, Data, Bool)
            }
            let action: TakeAction = peer.withState { state in
                guard state.running, state.staged.count > 0 else { return .skip }
                guard let session = usableSendingSession(peer), let counter = session.reserveSendCounter() else {
                    return .initiate
                }
                guard let packet = state.staged.popFirst() else { return .skip }
                io.stagedCount -= 1
                return .send(session, counter, packet, state.staged.count > 0)
            }
            switch action {
            case .skip:
                continue
            case .initiate:
                requestHandshakeInitiation(peer, io: io)
            case .send(let session, let counter, let packet, let hasMore):
                if hasMore {
                    scheduleStagedDrain(peer, io: io, wake: false)
                }
                return StagedTransport(peer: peer, session: session, counter: counter, packet: packet, run: io.run)
            }
        }
        return nil
    }

    func drainReadyPeers() {
        guard let io else { return }
        for _ in 0..<32 {
            guard let work = lock.withLock({ takeStaged(io) }) else { return }
            autoreleasepool { encryptAndSend(work, io: io) }
        }
        if lock.withLock({ !io.readyPeers.isEmpty }) { io.outboundReady.add(data: 1) }
    }

    static func paddingSize(_ count: Int, mtu: Int) -> Int {
        guard mtu > 0 else { return ((count + 15) & ~15) - count }
        let lastUnit = count > mtu ? count % mtu : count
        return min(mtu, (lastUnit + 15) & ~15) - lastUnit
    }

    private static let paddingZeros = Data(count: 16)

    private func encryptAndSend(_ work: StagedTransport, io: DeviceIO) {
        let header = TransportHeader(receiver: work.session.remoteIndex, counter: work.counter)
        let mtu = io.tunnel.mtu
        let padding = min(Self.maxContentSize - work.packet.count,
                          Self.paddingSize(work.packet.count, mtu: mtu < 0 ? 1420 : min(mtu, Self.maxContentSize)))
        let payload: Data
        if padding == 0 {
            payload = work.packet
        } else {
            // The outbound lane owns this reusable scratch buffer. Tunnel and UDP
            // buffers keep their value ownership at the adapter boundary.
            io.paddingScratch.removeAll(keepingCapacity: true)
            io.paddingScratch.append(work.packet)
            io.paddingScratch.append(Self.paddingZeros.prefix(padding))
            payload = io.paddingScratch
        }
        guard let nonce = header.withNonceBytes({ try? ChaChaPoly.Nonce(data: $0) }),
              let box = try? ChaChaPoly.seal(payload, using: work.session.sendKey, nonce: nonce) else { return }
        var datagram = Data(capacity: TransportHeader.minimumPacketSize + payload.count)
        header.append(to: &datagram)
        datagram.append(box.ciphertext)
        datagram.append(box.tag)

        let peer = work.peer
        let endpoint: IPEndpoint? = lock.withLock {
            guard work.run == io.run, io.state == .up, peers[peer.publicKey] === peer,
                  !work.session.isSendingExpired,
                  case .keypair(let owner, let session)? = indices.lookup(work.session.localIndex),
                  owner === peer, session === work.session else { return nil }
            let peerSnapshot: (running: Bool, endpoint: IPEndpoint?, keepaliveInterval: UInt16) = peer.withState {
                ($0.running, $0.endpoint, $0.persistentKeepaliveInterval)
            }
            guard peerSnapshot.running else { return nil }
            guard protocolNow().elapsed(since: work.session.created) < WireGuardTiming.rejectAfterTime else {
                io.stagedDrops += 1
                requestHandshakeInitiation(peer, io: io)
                return nil
            }
            timerAuthenticatedTraversal(peer, interval: peerSnapshot.keepaliveInterval, io: io)
            timerAuthenticatedSent(peer, io: io)
            if !work.packet.isEmpty { timerDataSent(peer, io: io) }
            return peerSnapshot.endpoint
        }
        guard let endpoint else { return }

        do {
            try io.transport.send(datagram, to: endpoint)
        } catch {
            return
        }

        lock.withLock {
            guard work.run == io.run, io.state == .up, peers[peer.publicKey] === peer else { return }
            let running = peer.withState { state -> Bool in
                guard state.running else { return false }
                state.txBytes &+= UInt64(datagram.count)
                return true
            }
            guard running else { return }
            if let current = peer.keypairs.current,
               current.nextSendCounter > WireGuardTiming.rekeyAfterMessages ||
               (current.isInitiator && protocolNow().elapsed(since: current.created) > WireGuardTiming.rekeyAfterTime) {
                requestHandshakeInitiation(peer, io: io)
            }
        }
    }

    func admitDatagram(_ incoming: DeviceIO.FromWire, generation: UInt64) -> Bool {
        guard let io, (TransportHeader.minimumPacketSize...Self.maxSegmentSize).contains(incoming.data.count) else {
            return false
        }
        switch WireGuardMessageType(packet: incoming.data) {
        case .transport:
            guard let header = TransportHeader(header: incoming.data),
                  case .keypair(let owner, let keypair)? = indices.lookup(header.receiver),
                  protocolNow().elapsed(since: keypair.created) <= WireGuardTiming.rejectAfterTime,
                  owner.withState({ $0.running }) else { return false }
            return io.inbound.offer(.init(wire: incoming, header: header, peer: owner, keypair: keypair),
                                    token: generation)
        case .initiation where incoming.data.count == HandshakePacket.Kind.initiation.size,
             .response where incoming.data.count == HandshakePacket.Kind.response.size,
             .cookieReply where incoming.data.count == CookieReply.size:
            return io.handshake.offer(incoming, token: generation)
        default:
            return false
        }
    }

    func decryptTransportBatch(_ batch: [DeviceIO.EncryptedTransport]) {
        guard let io else { return }
        var outgoing: [Data] = []
        outgoing.reserveCapacity(batch.count)
        for work in batch {
            if let packet = decryptTransport(work, io: io) {
                outgoing.append(packet)
            }
        }
        if !outgoing.isEmpty {
            try? io.tunnel.writeBatch(outgoing)
        }
    }

    private func decryptTransport(_ work: DeviceIO.EncryptedTransport, io: DeviceIO) -> Data? {
        let sealed = work.wire.data.dropFirst(TransportHeader.size)
        guard let nonce = work.header.withNonceBytes({ try? ChaChaPoly.Nonce(data: $0) }),
              let box = try? ChaChaPoly.SealedBox(
                  nonce: nonce, ciphertext: sealed.dropLast(ChaCha20Poly1305.tagLength),
                  tag: sealed.suffix(ChaCha20Poly1305.tagLength)
              ),
              let plaintext = try? ChaChaPoly.open(box, using: work.keypair.receiveKey) else { return nil }
        return lock.withLock {
            guard work.wire.run == io.run, canRun(work.peer, io: io) else { return nil }
            return receiveAuthenticated(plaintext, work, io: io)
        }
    }

    private func receiveAuthenticated(
        _ plaintext: Data, _ work: DeviceIO.EncryptedTransport, io: DeviceIO
    ) -> Data? {
        let peer = work.peer
        let now = protocolNow()
        guard now.elapsed(since: work.keypair.created) <= WireGuardTiming.rejectAfterTime else { return nil }
        let accepted = acceptAuthenticatedTransport(counter: work.header.counter, with: work.keypair, from: peer)
        guard accepted != .rejected else { return nil }

        if accepted == .confirmed {
            timer(.retransmitHandshake, for: peer, after: nil, io: io)
            timer(.initiate, for: peer, after: nil, io: io)
        }

        let currentKeypair = peer.keypairs.current
        let keepalivePending = !plaintext.isEmpty && timerPending(.sendKeepalive, peer, io: io)
        let (triggerFinalRekey, persistentKeepaliveInterval) = peer.withState { state -> (Bool, UInt16) in
            if !state.roamingDisabled {
                state.endpoint = work.wire.source
            }
            if accepted == .confirmed {
                state.handshakeAttempts = 0
                state.sentLastMinuteHandshake = false
                state.lastHandshakeUnixNanoseconds = io.wallNow()
            }
            var finalRekey = false
            if !state.sentLastMinuteHandshake, let current = currentKeypair, current.isInitiator {
                let threshold = WireGuardTiming.rejectAfterTime - WireGuardTiming.keepaliveTimeout - WireGuardTiming.rekeyTimeout
                if now.elapsed(since: current.created) > threshold {
                    state.sentLastMinuteHandshake = true
                    finalRekey = true
                }
            }
            state.rxBytes &+= UInt64(work.wire.data.count)
            if keepalivePending {
                state.needAnotherKeepalive = true
            }
            return (finalRekey, state.persistentKeepaliveInterval)
        }

        if accepted == .confirmed {
            requestStagedDrain(peer)
        }
        if triggerFinalRekey {
            requestHandshakeInitiation(peer, io: io)
        }
        timerAuthenticatedTraversal(peer, interval: persistentKeepaliveInterval, io: io)
        timerAuthenticatedReceived(peer, io: io)
        guard !plaintext.isEmpty else { return nil }

        // WireGuard treats authenticated nonempty plaintext as data for timers,
        // counters and key confirmation before issuing any plaintext routing verdict.
        if !keepalivePending {
            timer(.sendKeepalive, for: peer, after: WireGuardTiming.keepaliveTimeout, io: io)
        }
        guard let packet = IPPacket(plaintext, inbound: true),
              allowedIPs.lookup(packet.address) === peer else { return nil }
        return packet.length == plaintext.count ? plaintext : plaintext.prefix(packet.length)
    }

    func handleHandshake(_ incoming: DeviceIO.FromWire) {
        lock.withLock {
            guard let io, io.state == .up, incoming.run == io.run else { return }
            if let reply = CookieReply(packet: incoming.data) {
                switch indices.lookup(reply.receiver) {
                case .handshake(let peer), .keypair(let peer, _):
                    if canRun(peer, io: io) { consumeCookieReply(reply) }
                default: break
                }
                return
            }
            guard let packet = HandshakePacket(packet: incoming.data), checkHandshakeMAC1(packet) else { return }
            if underLoad(io) {
                if !checkHandshakeMAC2(packet, from: incoming.source) {
                    if let reply = try? createCookieReply(for: packet, from: incoming.source, mac1Verified: true) {
                        try? io.transport.send(reply.bytes, to: incoming.source)
                    }
                    return
                }
                guard rateLimitAllows(incoming.source, io: io) else { return }
            }

            switch packet.kind {
            case .initiation:
                guard let peer = try? consumeHandshakeInitiation(packet, mac1Verified: true) else { return }
                let (running, keepaliveInterval) = peer.withState { state -> (Bool, UInt16) in
                    if !state.roamingDisabled { state.endpoint = incoming.source }
                    state.rxBytes &+= UInt64(incoming.data.count)
                    return (state.running, state.persistentKeepaliveInterval)
                }
                if peers[peer.publicKey] === peer, running {
                    timerAuthenticatedTraversal(peer, interval: keepaliveInterval, io: io)
                    timerAuthenticatedReceived(peer, io: io)
                }
                sendHandshakeResponse(peer, io: io)

            case .response:
                guard let (peer, _) = try? consumeHandshakeResponse(packet, mac1Verified: true),
                      peers[peer.publicKey] === peer else { return }
                let keepaliveInterval: UInt16? = peer.withState { state in
                    guard state.running else { return nil }
                    if !state.roamingDisabled { state.endpoint = incoming.source }
                    state.rxBytes &+= UInt64(incoming.data.count)
                    state.handshakeAttempts = 0
                    state.sentLastMinuteHandshake = false
                    state.lastHandshakeUnixNanoseconds = io.wallNow()
                    return state.persistentKeepaliveInterval
                }
                guard let keepaliveInterval else { return }
                timerAuthenticatedTraversal(peer, interval: keepaliveInterval, io: io)
                timerAuthenticatedReceived(peer, io: io)
                timerSessionDerived(peer, io: io)
                timer(.retransmitHandshake, for: peer, after: nil, io: io)
                timer(.initiate, for: peer, after: nil, io: io)
                sendKeepalive(peer)
            }
        }
    }

    func underLoad(_ io: DeviceIO) -> Bool {
        let now = protocolNow()
        if io.handshake.depth >= 1024 / 8 {
            io.underLoadUntil = now.advanced(by: WireGuardTiming.underLoadAfterTime)
            return true
        }
        return io.underLoadUntil.map { $0 > now } ?? false
    }
}

private struct IPPacket {
    let address: IPAddress
    let length: Int

    init?(_ packet: Data, inbound: Bool) {
        guard let first = packet.first else { return nil }
        let bytes = packet.startIndex
        let offset: Int
        switch first >> 4 {
        case 4:
            guard packet.count >= 20 else { return nil }
            offset = inbound ? IPHeader.ipv4Source : IPHeader.ipv4Destination
            length = inbound ? Self.u16(packet, at: bytes + IPHeader.ipv4TotalLength) : packet.count
            guard (20...packet.count).contains(length) else { return nil }
            address = IPAddress(bytes: packet[(bytes + offset)..<(bytes + offset + 4)])!
        case 6:
            guard packet.count >= 40 else { return nil }
            offset = inbound ? IPHeader.ipv6Source : IPHeader.ipv6Destination
            length = inbound ? 40 + Self.u16(packet, at: bytes + IPHeader.ipv6PayloadLength) : packet.count
            guard length <= packet.count else { return nil }
            address = IPAddress(bytes: packet[(bytes + offset)..<(bytes + offset + 16)])!
        default:
            return nil
        }
    }

    private static func u16(_ data: Data, at index: Int) -> Int {
        (Int(data[index]) << 8) | Int(data[index + 1])
    }
}
