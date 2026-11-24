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
            guard let io, incoming.run == io.run, let peer = allowedIPs.lookup(route.address),
                  canRun(peer, io: io) else { return }
            stage(incoming.data, for: peer, io: io)
            requestStagedDrain(peer)
        }
    }

    private func stage(_ packet: Data, for peer: WireGuardPeer, io: DeviceIO) {
        peer.withState {
            if $0.staged.count == Self.stagedCapacity {
                _ = $0.staged.popFirst()
                io.stagedCount -= 1
                io.stagedDrops += 1
            }
        }
        if io.stagedCount >= Self.stagedBufferLimit {
            evictLongestStagedPeer(excluding: peer, io: io)
        }
        peer.withState {
            guard io.stagedCount < Self.stagedBufferLimit, $0.staged.append(packet) else {
                io.stagedDrops += 1
                return
            }
            io.stagedCount += 1
            io.stagedPeak = max(io.stagedPeak, io.stagedCount)
            io.peerStagedPeak = max(io.peerStagedPeak, $0.staged.count)
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
        guard let io, canRun(peer, io: io) else { return }
        if peer.withState({ $0.staged.count == 0 }) {
            stage(Data(), for: peer, io: io)
        }
        requestStagedDrain(peer)
    }

    private func usableSendingSession(_ peer: WireGuardPeer) -> SessionKeypair? {
        guard let keypair = peer.keypairs.current,
              keypair.nextSendCounter < ReplayFilter.rejectAfterMessages,
              protocolNow().elapsed(since: keypair.created) < WireGuardTiming.rejectAfterTime else { return nil }
        return keypair
    }

    func requestStagedDrain(_ peer: WireGuardPeer, wake: Bool = true) {
        guard let io, canRun(peer, io: io), peer.withState({ $0.staged.count > 0 }) else { return }
        if usableSendingSession(peer) != nil {
            let wasIdle = io.readyPeers.isEmpty
            io.readyPeers.append(peer)
            if wake && wasIdle { io.outboundReady.add(data: 1) }
        } else {
            requestHandshakeInitiation(peer, io: io)
        }
    }

    private func takeStaged(_ io: DeviceIO) -> StagedTransport? {
        while let peer = io.readyPeers.popFirst() {
            guard canRun(peer, io: io), peer.withState({ $0.staged.count > 0 }) else { continue }
            guard let session = usableSendingSession(peer), let counter = session.reserveSendCounter() else {
                requestHandshakeInitiation(peer, io: io)
                continue
            }
            guard let packet = peer.withState({ $0.staged.popFirst() }) else { continue }
            io.stagedCount -= 1
            requestStagedDrain(peer, wake: false)
            return StagedTransport(peer: peer, session: session, counter: counter, packet: packet, run: io.run)
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
        guard let nonce = try? ChaChaPoly.Nonce(data: header.nonce),
              let box = try? ChaChaPoly.seal(payload, using: work.session.sendKey, nonce: nonce) else { return }
        var datagram = header.bytes
        datagram.reserveCapacity(TransportHeader.minimumPacketSize + payload.count)
        datagram.append(box.ciphertext)
        datagram.append(box.tag)

        lock.withLock {
            let peer = work.peer
            guard work.run == io.run, canRun(peer, io: io), !work.session.isSendingExpired,
                  case .keypair(let owner, let session)? = indices.lookup(work.session.localIndex),
                  owner === peer, session === work.session else { return }
            guard protocolNow().elapsed(since: work.session.created) < WireGuardTiming.rejectAfterTime else {
                io.stagedDrops += 1
                requestHandshakeInitiation(peer, io: io)
                return
            }
            timerAuthenticatedTraversal(peer, io: io)
            timerAuthenticatedSent(peer, io: io)
            let sent = sendWire(datagram, to: peer, io: io)
            if !work.packet.isEmpty { timerDataSent(peer, io: io) }
            if sent, let current = peer.keypairs.current,
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

    func decryptTransport(_ work: DeviceIO.EncryptedTransport) {
        guard let io else { return }
        let sealed = work.wire.data.dropFirst(TransportHeader.size)
        guard let nonce = try? ChaChaPoly.Nonce(data: work.header.nonce),
              let box = try? ChaChaPoly.SealedBox(
                  nonce: nonce, ciphertext: sealed.dropLast(ChaCha20Poly1305.tagLength),
                  tag: sealed.suffix(ChaCha20Poly1305.tagLength)
              ),
              let plaintext = try? ChaChaPoly.open(box, using: work.keypair.receiveKey) else { return }
        let needsHandshakeLane = lock.withLock {
            guard work.wire.run == io.run, canRun(work.peer, io: io) else { return false }
            if needsFinalRekey(work.peer) { return true }
            receiveAuthenticated(plaintext, work, io: io, checkFreshness: false)
            return false
        }
        // Only the last-minute rekey can send a handshake in the middle of the
        // receive hooks. Hand off that commit without holding the device lock.
        if needsHandshakeLane {
            io.handshake.queue.sync {
                lock.withLock {
                    guard work.wire.run == io.run, canRun(work.peer, io: io) else { return }
                    receiveAuthenticated(plaintext, work, io: io, checkFreshness: true)
                }
            }
        }
    }

    private func needsFinalRekey(_ peer: WireGuardPeer) -> Bool {
        guard !peer.withState({ $0.sentLastMinuteHandshake }), let current = peer.keypairs.current,
              current.isInitiator else { return false }
        let threshold = WireGuardTiming.rejectAfterTime - WireGuardTiming.keepaliveTimeout - WireGuardTiming.rekeyTimeout
        return protocolNow().elapsed(since: current.created) > threshold
    }

    private func receiveAuthenticated(
        _ plaintext: Data, _ work: DeviceIO.EncryptedTransport, io: DeviceIO, checkFreshness: Bool
    ) {
        let peer = work.peer
        guard protocolNow().elapsed(since: work.keypair.created) <= WireGuardTiming.rejectAfterTime else { return }
        let accepted = acceptAuthenticatedTransport(counter: work.header.counter, with: work.keypair, from: peer)
        guard accepted != .rejected else { return }
        roam(peer, from: work.wire.source)
        if accepted == .confirmed {
            timerHandshakeComplete(peer, io: io)
            requestStagedDrain(peer)
        }

        if checkFreshness, needsFinalRekey(peer) {
            peer.withState { $0.sentLastMinuteHandshake = true }
            sendHandshakeInitiation(peer, retry: false, io: io)
        }
        timerAuthenticatedTraversal(peer, io: io)
        timerAuthenticatedReceived(peer, io: io)
        accountReceived(peer, bytes: work.wire.data.count)
        guard !plaintext.isEmpty else { return }

        // WireGuard treats authenticated nonempty plaintext as data for timers,
        // counters and key confirmation before issuing any plaintext routing verdict.
        timerDataReceived(peer, io: io)
        guard let packet = IPPacket(plaintext, inbound: true),
              allowedIPs.lookup(packet.address) === peer else { return }
        try? io.tunnel.write(plaintext.prefix(packet.length))
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
                if canRun(peer, io: io) {
                    timerAuthenticatedTraversal(peer, io: io)
                    timerAuthenticatedReceived(peer, io: io)
                }
                roam(peer, from: incoming.source)
                accountReceived(peer, bytes: incoming.data.count)
                sendHandshakeResponse(peer, io: io)

            case .response:
                guard let (peer, _) = try? consumeHandshakeResponse(packet, mac1Verified: true), canRun(peer, io: io) else { return }
                roam(peer, from: incoming.source)
                accountReceived(peer, bytes: incoming.data.count)
                timerAuthenticatedTraversal(peer, io: io)
                timerAuthenticatedReceived(peer, io: io)
                timerSessionDerived(peer, io: io)
                timerHandshakeComplete(peer, io: io)
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
