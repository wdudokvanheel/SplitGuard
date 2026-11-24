// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Foundation

extension WireGuardDevice {
    func createHandshakeInitiation(for peer: WireGuardPeer) throws -> HandshakePacket {
        try lock.withLock {
            try requireIdentity()
            guard peers[peer.publicKey] === peer else { throw NoiseHandshakeError.unknownPeer }
            return try peer.withState { state in
                guard !state.handshake.staticSharedSecret.isEmpty else { throw NoiseHandshakeError.authenticationFailed }
                var ephemeral = NoisePrivateKey.generate()
                defer { ephemeral.clear() }
                let ephemeralPublicKey = try ephemeral.publicKey()
                var transcript = NoiseTranscript(responder: peer.publicKey, ephemeral: ephemeralPublicKey)
                defer { transcript.clear() }

                var key = try transcript.deriveCipherKey(privateKey: ephemeral, publicKey: peer.publicKey)
                defer { SecretBytes.zero(&key) }
                let encryptedStatic = try transcript.seal(identity.publicKey.rawValue, key: key)
                SecretBytes.zero(&key)
                key = transcript.deriveCipherKey(state.handshake.staticSharedSecret)
                let encryptedTimestamp = try transcript.seal(timestampNow().rawRepresentation, key: key)

                let index = try indices.insertHandshake(for: peer)
                var packet = HandshakePacket(
                    sender: index, ephemeral: ephemeralPublicKey,
                    encryptedStatic: encryptedStatic, encryptedTimestamp: encryptedTimestamp
                )!
                state.cookieGenerator.addMACs(&packet, at: protocolNow())
                clearHandshake(&state.handshake, for: peer)
                state.handshake.phase = .initiationCreated
                state.handshake.localIndex = index
                swap(&state.handshake.localEphemeral, &ephemeral)
                swap(&state.handshake.transcript, &transcript)
                return packet
            }
        }
    }

    func consumeHandshakeInitiation(_ packet: HandshakePacket, mac1Verified: Bool = false) throws -> WireGuardPeer {
        try lock.withLock {
            try requireIdentity()
            guard let encryptedStatic = packet.encryptedStatic, let encryptedTimestamp = packet.encryptedTimestamp else {
                throw NoiseHandshakeError.invalidState
            }
            if !mac1Verified {
                guard cookieChecker.checkMAC1(packet) else { throw NoiseHandshakeError.invalidMAC1 }
            }
            let ephemeral = packet.ephemeral
            var transcript = NoiseTranscript(responder: identity.publicKey, ephemeral: ephemeral)
            defer { transcript.clear() }
            var key = try transcript.deriveCipherKey(privateKey: identity.privateKey, publicKey: ephemeral)
            defer { SecretBytes.zero(&key) }
            let remote = NoisePublicKey(rawValue: try transcript.open(encryptedStatic, key: key))!
            SecretBytes.zero(&key)
            guard let peer = peers[remote] else { throw NoiseHandshakeError.unknownPeer }
            try peer.withState { state in
                guard !state.handshake.staticSharedSecret.isEmpty else { throw NoiseHandshakeError.authenticationFailed }
                key = transcript.deriveCipherKey(state.handshake.staticSharedSecret)
                let timestamp = TAI64N(rawRepresentation: try transcript.open(encryptedTimestamp, key: key))!
                let now = protocolNow()
                guard timestamp > state.handshake.lastTimestamp else { throw NoiseHandshakeError.replayedTimestamp }
                if let last = state.handshake.lastInitiation,
                   now.elapsed(since: last) <= NoiseHandshakeState.initiationRate {
                    throw NoiseHandshakeError.initiationFlood
                }

                state.handshake.clearTranscript()
                state.handshake.phase = .initiationConsumed
                state.handshake.lastTimestamp = timestamp
                state.handshake.lastInitiation = now
                state.handshake.remoteIndex = packet.sender
                state.handshake.remoteEphemeral = ephemeral
                swap(&state.handshake.transcript, &transcript)
            }
            return peer
        }
    }

    /// Returns the outgoing response and installs its session in the responder's next slot.
    func createHandshakeResponse(for peer: WireGuardPeer) throws -> (HandshakePacket, SessionKeypair) {
        try lock.withLock {
            try requireIdentity()
            guard peers[peer.publicKey] === peer else { throw NoiseHandshakeError.unknownPeer }
            return try peer.withState { state in
                guard state.handshake.phase == .initiationConsumed else { throw NoiseHandshakeError.invalidState }
                var ephemeral = NoisePrivateKey.generate()
                defer { ephemeral.clear() }
                let ephemeralPublicKey = try ephemeral.publicKey()
                var transcript = state.handshake.transcript
                defer { transcript.clear() }
                transcript.mixHash(ephemeralPublicKey.rawValue)
                transcript.mixKey(ephemeralPublicKey.rawValue)
                try transcript.mixDH(privateKey: ephemeral, publicKey: state.handshake.remoteEphemeral)
                try transcript.mixDH(privateKey: ephemeral, publicKey: peer.publicKey)
                var key = transcript.mixPresharedKey(state.presharedKey)
                defer { SecretBytes.zero(&key) }
                let empty = try transcript.seal(Data(), key: key)
                let now = protocolNow()
                let index = try indices.insertHandshake(for: peer)
                let remoteIndex = state.handshake.remoteIndex
                let keypair: SessionKeypair
                do {
                    keypair = try beginSymmetricSession(
                        for: peer, chainKey: transcript.chainKey, initiator: false, at: now,
                        localIndex: index, remoteIndex: remoteIndex
                    )
                } catch {
                    indices.deleteHandshake(index, for: peer)
                    throw error
                }
                var packet = HandshakePacket(
                    sender: index, receiver: remoteIndex, ephemeral: ephemeralPublicKey, encryptedEmpty: empty
                )!
                state.cookieGenerator.addMACs(&packet, at: now)
                clearHandshake(&state.handshake, for: peer)
                return (packet, keypair)
            }
        }
    }

    /// Authenticates the response and installs its session in the initiator's current slot.
    func consumeHandshakeResponse(
        _ packet: HandshakePacket, mac1Verified: Bool = false
    ) throws -> (WireGuardPeer, SessionKeypair) {
        try lock.withLock {
            try requireIdentity()
            guard let index = packet.receiver, let empty = packet.encryptedEmpty else {
                throw NoiseHandshakeError.invalidState
            }
            if !mac1Verified {
                guard cookieChecker.checkMAC1(packet) else { throw NoiseHandshakeError.invalidMAC1 }
            }
            guard case .handshake(let peer)? = indices.lookup(index), peers[peer.publicKey] === peer else {
                throw NoiseHandshakeError.invalidState
            }
            return try peer.withState { state in
                guard state.handshake.phase == .initiationCreated, state.handshake.localIndex == index else {
                    throw NoiseHandshakeError.invalidState
                }
                var transcript = state.handshake.transcript
                defer { transcript.clear() }
                let ephemeral = packet.ephemeral
                transcript.mixHash(ephemeral.rawValue)
                transcript.mixKey(ephemeral.rawValue)
                try transcript.mixDH(privateKey: state.handshake.localEphemeral, publicKey: ephemeral)
                try transcript.mixDH(privateKey: identity.privateKey, publicKey: ephemeral)
                var key = transcript.mixPresharedKey(state.presharedKey)
                defer { SecretBytes.zero(&key) }
                _ = try transcript.open(empty, key: key)

                let keypair = try beginSymmetricSession(
                    for: peer, chainKey: transcript.chainKey, initiator: true, at: protocolNow(),
                    localIndex: index, remoteIndex: packet.sender
                )
                state.handshake.clearExchange()
                return (peer, keypair)
            }
        }
    }

    enum TransportAcceptance: Equatable {
        case rejected
        case accepted
        case confirmed
    }

    /// Call after transport AEAD succeeds. Atomically checks replay and confirms a responder's next session.
    func acceptAuthenticatedTransport(
        counter: UInt64, with keypair: SessionKeypair, from peer: WireGuardPeer
    ) -> TransportAcceptance {
        lock.withLock {
            guard peers[peer.publicKey] === peer else { return .rejected }
            return peer.keypairs.withSlots { slots in
                guard case .keypair(let owner, let indexedKeypair)? = indices.lookup(keypair.localIndex),
                      owner === peer, indexedKeypair === keypair,
                      slots.next === keypair || slots.current === keypair || slots.previous === keypair,
                      keypair.validateReceivedCounter(counter) else { return .rejected }
                guard slots.next === keypair else { return .accepted }
                if let previous = slots.previous { indices.delete(previous) }
                slots.previous = slots.current
                slots.current = keypair
                slots.next = nil
                return .confirmed
            }
        }
    }

    func checkHandshakeMAC1(_ packet: HandshakePacket) -> Bool {
        lock.withLock { !identity.privateKey.isZero && cookieChecker.checkMAC1(packet) }
    }

    /// Verify MAC2 against the active cookie secret. Callers verify MAC1 first.
    func checkHandshakeMAC2(_ packet: HandshakePacket, from source: IPEndpoint) -> Bool {
        lock.withLock { cookieChecker.checkMAC2(packet, from: source, at: protocolNow()) }
    }

    func createCookieReply(
        for packet: HandshakePacket, from source: IPEndpoint, mac1Verified: Bool = false
    ) throws -> CookieReply {
        try lock.withLock {
            try requireIdentity()
            if !mac1Verified {
                guard cookieChecker.checkMAC1(packet) else { throw NoiseHandshakeError.invalidMAC1 }
            }
            return try cookieChecker.createReply(packet, from: source, at: protocolNow())
        }
    }

    @discardableResult
    func consumeCookieReply(_ reply: CookieReply) -> Bool {
        lock.withLock {
            let peer: WireGuardPeer
            switch indices.lookup(reply.receiver) {
            case .handshake(let owner), .keypair(let owner, _): peer = owner
            case nil: return false
            }
            guard peers[peer.publicKey] === peer else { return false }
            return peer.withState { $0.cookieGenerator.consumeReply(reply, at: protocolNow()) }
        }
    }

    private func requireIdentity() throws {
        guard !identity.privateKey.isZero else { throw NoiseHandshakeError.missingIdentity }
    }

    private func beginSymmetricSession(
        for peer: WireGuardPeer, chainKey: Data, initiator: Bool, at now: ProtocolInstant,
        localIndex: UInt32, remoteIndex: UInt32
    ) throws -> SessionKeypair {
        var keys = NoiseKDF.kdf2(key: chainKey, input: Data())
        defer {
            SecretBytes.zero(&keys.0)
            SecretBytes.zero(&keys.1)
        }
        let keypair = try SessionKeypair(
            sendKey: initiator ? keys.0 : keys.1, receiveKey: initiator ? keys.1 : keys.0,
            created: now, isInitiator: initiator, localIndex: localIndex, remoteIndex: remoteIndex
        )
        try peer.keypairs.withSlots { slots in
            guard indices.swapForKeypair(keypair, for: peer) else { throw NoiseHandshakeError.invalidState }

            let previous = slots.previous
            if initiator {
                if let next = slots.next {
                    slots.next = nil
                    slots.previous = next
                    if let current = slots.current { indices.delete(current) }
                } else {
                    slots.previous = slots.current
                }
                slots.current = keypair
            } else {
                if let next = slots.next { indices.delete(next) }
                slots.next = keypair
                slots.previous = nil
            }
            if let previous { indices.delete(previous) }
        }
        return keypair
    }
}
