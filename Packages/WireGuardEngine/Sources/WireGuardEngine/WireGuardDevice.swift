// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Darwin
import Foundation

final class WireGuardPeer {
    struct State {
        var presharedKey = NoisePresharedKey.zero
        var endpoint: IPEndpoint?
        var persistentKeepaliveInterval: UInt16 = 0

        // Unix nanoseconds for UAPI display. Protocol timers use ProtocolInstant.
        var lastHandshakeUnixNanoseconds: Int64 = 0
        var txBytes: UInt64 = 0
        var rxBytes: UInt64 = 0
        var handshake = NoiseHandshakeState()
        var cookieGenerator: CookieGenerator

        init(publicKey: NoisePublicKey) {
            cookieGenerator = CookieGenerator(for: publicKey)
        }
    }

    let publicKey: NoisePublicKey
    let keypairs = SessionKeypairs()
    private let lock = NSLock()
    private var state: State

    init(publicKey: NoisePublicKey) {
        self.publicKey = publicKey
        state = State(publicKey: publicKey)
    }

    /// Lock order is device, peer, keypair slots, then index table or session.
    /// Callers must release peer state before acquiring the device lock.
    func withState<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&state) }
    }

    deinit {
        state.presharedKey.clear()
        state.handshake.clearExchange()
        SecretBytes.zero(&state.handshake.staticSharedSecret)
        state.cookieGenerator.clear()
    }
}

enum UAPIError: Error, Equatable {
    case inputTooLong
    case malformedLine
    case invalidValue(key: String)
    case portInUse

    var code: Int64 {
        switch self {
        case .inputTooLong: return -Int64(EIO)
        case .malformedLine: return -Int64(EPROTO)
        case .invalidValue: return -Int64(EINVAL)
        case .portInUse: return -Int64(EADDRINUSE)
        }
    }
}

/// Owns the static identity, peer objects, allowed-IP routing and local session indices.
/// UAPI applies directly to this state, one line at a time, including on errors.
final class WireGuardDevice {
    struct StaticIdentity {
        fileprivate(set) var privateKey = NoisePrivateKey.zero
        fileprivate(set) var publicKey = NoisePublicKey.zero
    }

    private struct PeerSelection {
        var peer: WireGuardPeer?
        let created: Bool
    }

    private static let maxPeers = 1 << 16
    private static let maxScanTokenSize = 64 * 1024

    private let lock = NSLock()
    private var identity = StaticIdentity()
    private var cookieChecker = CookieChecker(for: .zero)
    private let protocolNow: () -> ProtocolInstant
    private let timestampNow: () -> TAI64N
    private var port: UInt16 = 0
    private var mark: UInt32 = 0
    private var peers: [NoisePublicKey: WireGuardPeer] = [:]
    private let allowedIPs = AllowedIPs<WireGuardPeer>()
    let indices = SessionIndexTable<WireGuardPeer>()

    init(
        protocolNow: @escaping () -> ProtocolInstant = ProtocolInstant.now,
        timestampNow: @escaping () -> TAI64N = TAI64N.now
    ) {
        self.protocolNow = protocolNow
        self.timestampNow = timestampNow
    }

    var staticIdentity: StaticIdentity { lock.withLock { identity } }
    var listenPort: UInt16 { lock.withLock { port } }
    var firewallMark: UInt32 { lock.withLock { mark } }

    func peer(for key: NoisePublicKey) -> WireGuardPeer? {
        lock.withLock { peers[key] }
    }

    func peer(for address: IPAddress) -> WireGuardPeer? {
        allowedIPs.lookup(address)
    }

    func ipcSet(_ config: String) throws {
        try lock.withLock {
            var selection: PeerSelection?
            var remaining = config.utf8[...]
            while !remaining.isEmpty {
                // Go ScanLines strips a single CR before LF or EOF. The scanner
                // needs room for the line terminator and caps the raw token at 64 KiB.
                let scan = remaining.prefix(Self.maxScanTokenSize)
                let newline = scan.firstIndex(of: 10)
                guard newline != nil || scan.count < Self.maxScanTokenSize else {
                    throw UAPIError.inputTooLong
                }
                var line = remaining[..<(newline ?? remaining.endIndex)]
                remaining = newline.map { remaining[remaining.index(after: $0)...] }
                    ?? remaining[remaining.endIndex...]
                if line.last == 13 { line = line.dropLast() }
                if line.isEmpty { return }
                guard let equals = line.firstIndex(of: 61) else { throw UAPIError.malformedLine }

                let key = String(decoding: line[..<equals], as: UTF8.self)
                let value = String(decoding: line[line.index(after: equals)...], as: UTF8.self)
                if key == "public_key" {
                    selection = try selectPeer(value[...])
                } else if let selected = selection {
                    selection = try setPeerField(key, value[...], selected)
                } else {
                    try setDeviceField(key, value[...])
                }
            }
        }
    }

    func ipcGet() -> String {
        lock.withLock {
            var result = ""
            if !identity.privateKey.isZero { result += "private_key=\(identity.privateKey.hex)\n" }
            if port != 0 { result += "listen_port=\(port)\n" }
            if mark != 0 { result += "fwmark=\(mark)\n" }

            // Go map iteration leaves cross-peer order unspecified.
            let orderedPeers = peers.values.sorted {
                $0.publicKey.rawValue.lexicographicallyPrecedes($1.publicKey.rawValue)
            }
            for peer in orderedPeers {
                peer.withState { state in
                    let nanosecondsPerSecond: Int64 = 1_000_000_000
                    let handshake = state.lastHandshakeUnixNanoseconds
                    result += "public_key=\(peer.publicKey.hex)\n"
                    result += "preshared_key=\(state.presharedKey.hex)\n"
                    result += "protocol_version=1\n"
                    if let endpoint = state.endpoint { result += "endpoint=\(endpoint)\n" }
                    result += "last_handshake_time_sec=\(handshake / nanosecondsPerSecond)\n"
                    result += "last_handshake_time_nsec=\(handshake % nanosecondsPerSecond)\n"
                    result += "tx_bytes=\(state.txBytes)\n"
                    result += "rx_bytes=\(state.rxBytes)\n"
                    result += "persistent_keepalive_interval=\(state.persistentKeepaliveInterval)\n"
                }
                for prefix in allowedIPs.prefixes(for: peer) {
                    result += "allowed_ip=\(prefix)\n"
                }
            }
            return result
        }
    }

    private func setDeviceField(_ key: String, _ value: Substring) throws {
        let invalid = UAPIError.invalidValue(key: key)
        switch key {
        case "private_key":
            guard let privateKey = NoisePrivateKey(hex: value, preservingZero: true) else { throw invalid }
            if !identity.privateKey.matches(privateKey) {
                guard let publicKey = try? privateKey.publicKey() else { throw invalid }
                removePeer(publicKey)
                identity.privateKey.clear()
                identity = StaticIdentity(privateKey: privateKey, publicKey: publicKey)
                cookieChecker.clear()
                cookieChecker = CookieChecker(for: publicKey)
                for peer in peers.values {
                    peer.withState { state in
                        clearHandshake(&state.handshake, for: peer)
                        state.handshake.precompute(privateKey: privateKey, remote: peer.publicKey)
                        peer.keypairs.withSlots {
                            $0.current?.expireSending()
                            $0.next?.expireSending()
                        }
                    }
                }
            }
        case "listen_port":
            guard let port = parseUnsignedDecimal(value, as: UInt16.self) else { throw invalid }
            self.port = port
        case "fwmark":
            guard let mark = parseUnsignedDecimal(value, as: UInt32.self) else { throw invalid }
            self.mark = mark
        case "replace_peers":
            guard value == "true" else { throw invalid }
            for publicKey in Array(peers.keys) {
                removePeer(publicKey)
            }
        default:
            throw invalid
        }
    }

    private func selectPeer(_ value: Substring) throws -> PeerSelection {
        let invalid = UAPIError.invalidValue(key: "public_key")
        guard let key = NoisePublicKey(hex: value) else { throw invalid }
        if identity.publicKey.matches(key) { return PeerSelection(peer: nil, created: false) }
        if let peer = peers[key] { return PeerSelection(peer: peer, created: false) }
        guard peers.count < Self.maxPeers else { throw invalid }
        let peer = WireGuardPeer(publicKey: key)
        peer.withState { $0.handshake.precompute(privateKey: identity.privateKey, remote: key) }
        peers[key] = peer
        return PeerSelection(peer: peer, created: true)
    }

    private func setPeerField(_ key: String, _ value: Substring, _ selected: PeerSelection) throws -> PeerSelection {
        let invalid = UAPIError.invalidValue(key: key)
        let peer = selected.peer
        switch key {
        case "update_only", "remove":
            guard value == "true" else { throw invalid }
            if let peer, key == "remove" || selected.created {
                removePeer(peer.publicKey)
                return PeerSelection(peer: nil, created: selected.created)
            }
        case "preshared_key":
            guard let preshared = NoisePresharedKey(hex: value) else { throw invalid }
            peer?.withState {
                $0.presharedKey.clear()
                $0.presharedKey = preshared
            }
        case "endpoint":
            guard let endpoint = IPEndpoint(value) else { throw invalid }
            peer?.withState { $0.endpoint = endpoint }
        case "persistent_keepalive_interval":
            guard let interval = parseUnsignedDecimal(value, as: UInt16.self) else { throw invalid }
            peer?.withState { $0.persistentKeepaliveInterval = interval }
        case "replace_allowed_ips":
            guard value == "true" else { throw invalid }
            if let peer { allowedIPs.removeAll(for: peer) }
        case "allowed_ip":
            guard let prefix = IPPrefix(value) else { throw invalid }
            if let peer { allowedIPs.insert(prefix, for: peer) }
        case "protocol_version":
            guard value == "1" else { throw invalid }
        default:
            throw invalid
        }
        return selected
    }

    private func removePeer(_ publicKey: NoisePublicKey) {
        guard let peer = peers.removeValue(forKey: publicKey) else { return }
        allowedIPs.removeAll(for: peer)
        peer.withState { state in
            clearHandshake(&state.handshake, for: peer)
            SecretBytes.zero(&state.handshake.staticSharedSecret)
            state.presharedKey.clear()
            state.cookieGenerator.clear()
            peer.keypairs.withSlots {
                for keypair in [$0.previous, $0.current, $0.next].compactMap({ $0 }) {
                    indices.delete(keypair)
                    keypair.expireSending()
                }
                $0 = SessionKeypairs.Slots()
            }
        }
    }

    private func clearHandshake(_ handshake: inout NoiseHandshakeState, for peer: WireGuardPeer) {
        if let index = handshake.localIndex { indices.deleteHandshake(index, for: peer) }
        handshake.clearExchange()
    }

    deinit {
        identity.privateKey.clear()
        cookieChecker.clear()
    }
}

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

    func consumeHandshakeInitiation(_ packet: HandshakePacket) throws -> WireGuardPeer {
        try lock.withLock {
            try requireIdentity()
            guard let encryptedStatic = packet.encryptedStatic, let encryptedTimestamp = packet.encryptedTimestamp else {
                throw NoiseHandshakeError.invalidState
            }
            guard cookieChecker.checkMAC1(packet) else { throw NoiseHandshakeError.invalidMAC1 }
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
    func consumeHandshakeResponse(_ packet: HandshakePacket) throws -> (WireGuardPeer, SessionKeypair) {
        try lock.withLock {
            try requireIdentity()
            guard let index = packet.receiver, let empty = packet.encryptedEmpty else {
                throw NoiseHandshakeError.invalidState
            }
            guard cookieChecker.checkMAC1(packet) else { throw NoiseHandshakeError.invalidMAC1 }
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

    /// Phase 4 decides when to require MAC2 and always checks MAC1 first.
    func checkHandshakeMAC2(_ packet: HandshakePacket, from source: IPEndpoint) -> Bool {
        lock.withLock { cookieChecker.checkMAC2(packet, from: source, at: protocolNow()) }
    }

    func createCookieReply(for packet: HandshakePacket, from source: IPEndpoint) throws -> CookieReply {
        try lock.withLock {
            try requireIdentity()
            guard cookieChecker.checkMAC1(packet) else { throw NoiseHandshakeError.invalidMAC1 }
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
