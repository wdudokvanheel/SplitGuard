// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import Security

private enum HandshakeMAC {
    static let refreshTime: UInt64 = 120 * 1_000_000_000
    static let zero = Data(count: BLAKE2s.macLength)

    static func isFresh(_ created: ProtocolInstant?, at now: ProtocolInstant) -> Bool {
        guard let created else { return false }
        return now.elapsed(since: created) <= refreshTime
    }

    static func randomBytes(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else {
            SecretBytes.zero(&bytes)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return bytes
    }
}

private struct HandshakeMACKeys {
    let mac1: Data
    let cookieEncryption: Data

    init(for key: NoisePublicKey) {
        mac1 = BLAKE2s.hash(Data("mac1----".utf8), key.rawValue)
        cookieEncryption = BLAKE2s.hash(Data("cookie--".utf8), key.rawValue)
    }

    func authenticate(_ packet: HandshakePacket) -> Data {
        // BLAKE2s always returns a 32-byte key, a valid length for mac128.
        try! BLAKE2s.mac128(packet.mac1Input, key: mac1)
    }
}

/// Owned by the device lock. A new local identity gets a new checker.
struct CookieChecker {
    private let keys: HandshakeMACKeys
    private var secret = Data()
    private var secretSet: ProtocolInstant?

    init(for key: NoisePublicKey) {
        keys = HandshakeMACKeys(for: key)
    }

    func checkMAC1(_ packet: HandshakePacket) -> Bool {
        SecretBytes.equal(keys.authenticate(packet), packet.mac1)
    }

    func checkMAC2(_ packet: HandshakePacket, from source: IPEndpoint, at now: ProtocolInstant) -> Bool {
        guard HandshakeMAC.isFresh(secretSet, at: now) else { return false }
        var cookie = deriveCookie(for: source)
        defer { SecretBytes.zero(&cookie) }
        let mac = try! BLAKE2s.mac128(packet.mac2Input, key: cookie)
        return SecretBytes.equal(mac, packet.mac2)
    }

    /// Call after checking MAC1. The received MAC1 authenticates the cookie reply's ciphertext.
    mutating func createReply(_ packet: HandshakePacket, from source: IPEndpoint, at now: ProtocolInstant)
        throws -> CookieReply {
        if !HandshakeMAC.isFresh(secretSet, at: now) {
            clear()
            secret = try HandshakeMAC.randomBytes(count: BLAKE2s.digestLength)
            secretSet = now
        }

        var cookie = deriveCookie(for: source)
        defer { SecretBytes.zero(&cookie) }
        let nonce = try HandshakeMAC.randomBytes(count: XChaCha20Poly1305.nonceLength)
        let encrypted = try XChaCha20Poly1305.seal(
            cookie, key: keys.cookieEncryption, nonce: nonce, authenticating: packet.mac1
        )
        return CookieReply(receiver: packet.sender, nonce: nonce, encryptedCookie: encrypted)!
    }

    mutating func clear() {
        SecretBytes.zero(&secret)
        secretSet = nil
    }

    private func deriveCookie(for source: IPEndpoint) -> Data {
        // This is called only with an initialized 32-byte secret.
        try! BLAKE2s.mac128(Data(source.destinationBytes), key: secret)
    }
}

/// Owned by the peer lock. MAC1 and encryption keys are derived from the remote static key.
struct CookieGenerator {
    private let keys: HandshakeMACKeys
    private var cookie = Data()
    private var cookieSet: ProtocolInstant?
    private var lastMAC1: Data?

    init(for key: NoisePublicKey) {
        keys = HandshakeMACKeys(for: key)
    }

    mutating func addMACs(_ packet: inout HandshakePacket, at now: ProtocolInstant) {
        let mac1 = keys.authenticate(packet)
        packet.setMAC1(mac1)
        lastMAC1 = mac1
        if HandshakeMAC.isFresh(cookieSet, at: now) {
            packet.setMAC2(try! BLAKE2s.mac128(packet.mac2Input, key: cookie))
        } else {
            packet.setMAC2(HandshakeMAC.zero)
        }
    }

    mutating func consumeReply(_ reply: CookieReply, at now: ProtocolInstant) -> Bool {
        guard let lastMAC1, let opened = try? XChaCha20Poly1305.open(
            reply.encryptedCookie, key: keys.cookieEncryption, nonce: reply.nonce, authenticating: lastMAC1
        ) else { return false }
        SecretBytes.zero(&cookie)
        cookie = opened
        cookieSet = now
        return true
    }

    mutating func clear() {
        SecretBytes.zero(&cookie)
        cookieSet = nil
        lastMAC1 = nil
    }
}
