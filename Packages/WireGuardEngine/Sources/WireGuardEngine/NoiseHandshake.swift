// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Foundation

enum NoiseHandshakeError: Error, Equatable {
    case unknownPeer
    case missingIdentity
    case invalidState
    case invalidMAC1
    case authenticationFailed
    case replayedTimestamp
    case initiationFlood
}

struct NoiseHandshakeState {
    enum Phase {
        case idle
        case initiationCreated
        case initiationConsumed
    }

    static let initiationRate: UInt64 = 1_000_000_000 / 50

    var phase = Phase.idle
    var transcript = NoiseTranscript()
    var localEphemeral = NoisePrivateKey.zero
    var localIndex: UInt32?
    var remoteEphemeral = NoisePublicKey.zero
    var remoteIndex: UInt32 = 0
    var staticSharedSecret = Data()
    var lastTimestamp = TAI64N(rawRepresentation: Data(count: TAI64N.length))!
    var lastInitiation: ProtocolInstant?

    mutating func clearExchange() {
        clearTranscript()
        localIndex = nil
    }

    mutating func clearTranscript() {
        transcript.clear()
        localEphemeral.clear()
        remoteEphemeral = .zero
        remoteIndex = 0
        phase = .idle
    }

    mutating func precompute(privateKey: NoisePrivateKey, remote: NoisePublicKey) {
        SecretBytes.zero(&staticSharedSecret)
        staticSharedSecret = privateKey.isZero ? Data() :
            (try? X25519.sharedSecret(privateKey: privateKey.rawValue, publicKey: remote.rawValue)) ?? Data()
    }
}

struct NoiseTranscript {
    private static let initialChainKey = BLAKE2s.hash(Data("Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s".utf8))
    private static let initialHash = BLAKE2s.hash(initialChainKey, Data("WireGuard v1 zx2c4 Jason@zx2c4.com".utf8))
    private static let zeroNonce = Data(count: ChaCha20Poly1305.nonceLength)

    private(set) var chainKey = Data()
    private var hash = Data()

    init() {}

    init(responder: NoisePublicKey, ephemeral: NoisePublicKey) {
        chainKey = NoiseKDF.kdf1(key: Self.initialChainKey, input: ephemeral.rawValue)
        hash = BLAKE2s.hash(BLAKE2s.hash(Self.initialHash, responder.rawValue), ephemeral.rawValue)
    }

    mutating func clear() {
        SecretBytes.zero(&chainKey)
        SecretBytes.zero(&hash)
        chainKey = Data()
        hash = Data()
    }

    mutating func mixKey(_ input: Data) {
        let next = NoiseKDF.kdf1(key: chainKey, input: input)
        SecretBytes.zero(&chainKey)
        chainKey = next
    }

    mutating func mixHash(_ input: Data) {
        let next = BLAKE2s.hash(hash, input)
        SecretBytes.zero(&hash)
        hash = next
    }

    mutating func mixDH(privateKey: NoisePrivateKey, publicKey: NoisePublicKey) throws {
        var secret = try X25519.sharedSecret(privateKey: privateKey.rawValue, publicKey: publicKey.rawValue)
        defer { SecretBytes.zero(&secret) }
        mixKey(secret)
    }

    mutating func deriveCipherKey(_ input: Data) -> Data {
        let (next, key) = NoiseKDF.kdf2(key: chainKey, input: input)
        SecretBytes.zero(&chainKey)
        chainKey = next
        return key
    }

    mutating func deriveCipherKey(privateKey: NoisePrivateKey, publicKey: NoisePublicKey) throws -> Data {
        var secret = try X25519.sharedSecret(privateKey: privateKey.rawValue, publicKey: publicKey.rawValue)
        defer { SecretBytes.zero(&secret) }
        return deriveCipherKey(secret)
    }

    mutating func mixPresharedKey(_ psk: NoisePresharedKey) -> Data {
        var outputs = NoiseKDF.kdf3(key: chainKey, input: psk.rawValue)
        SecretBytes.zero(&chainKey)
        chainKey = outputs.0
        mixHash(outputs.1)
        SecretBytes.zero(&outputs.1)
        return outputs.2
    }

    mutating func seal(_ plaintext: Data, key: Data) throws -> Data {
        let ciphertext = try ChaCha20Poly1305.seal(plaintext, key: key, nonce: Self.zeroNonce, authenticating: hash)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func open(_ ciphertext: Data, key: Data) throws -> Data {
        guard let plaintext = try? ChaCha20Poly1305.open(
            ciphertext, key: key, nonce: Self.zeroNonce, authenticating: hash
        ) else { throw NoiseHandshakeError.authenticationFailed }
        mixHash(ciphertext)
        return plaintext
    }
}
