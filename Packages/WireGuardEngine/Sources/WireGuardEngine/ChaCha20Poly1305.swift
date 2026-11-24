// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

enum ChaCha20Poly1305 {
    static let keyLength = 32
    static let nonceLength = 12
    static let tagLength = 16
    private static let maximumPlaintextLength: UInt64 = (1 << 38) - 64

    static func nonce(counter: UInt64) -> Data {
        var nonce = Data(count: 4)
        withUnsafeBytes(of: counter.littleEndian) { nonce.append(contentsOf: $0) }
        return nonce
    }

    static func seal(_ plaintext: Data, key: Data, counter: UInt64, authenticating aad: Data = Data()) throws -> Data {
        try seal(plaintext, key: key, nonce: nonce(counter: counter), authenticating: aad)
    }

    static func open(_ sealed: Data, key: Data, counter: UInt64, authenticating aad: Data = Data()) throws -> Data {
        try open(sealed, key: key, nonce: nonce(counter: counter), authenticating: aad)
    }

    /// WireGuard sends ciphertext followed by the authentication tag.
    static func seal(_ plaintext: Data, key: Data, nonce: Data, authenticating aad: Data) throws -> Data {
        guard key.count == keyLength else { throw WireGuardCryptoError.invalidKeyLength }
        guard nonce.count == nonceLength else { throw WireGuardCryptoError.invalidNonceLength }
        guard UInt64(plaintext.count) <= maximumPlaintextLength else { throw WireGuardCryptoError.messageTooLarge }
        let box = try ChaChaPoly.seal(
            plaintext, using: SymmetricKey(data: key), nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad
        )
        var output = box.ciphertext
        output.append(box.tag)
        return output
    }

    static func open(_ sealed: Data, key: Data, nonce: Data, authenticating aad: Data) throws -> Data {
        guard key.count == keyLength else { throw WireGuardCryptoError.invalidKeyLength }
        guard nonce.count == nonceLength else { throw WireGuardCryptoError.invalidNonceLength }
        guard sealed.count >= tagLength else { throw CryptoKitError.authenticationFailure }
        let ciphertextLength = sealed.count - tagLength
        guard UInt64(ciphertextLength) <= maximumPlaintextLength else { throw WireGuardCryptoError.messageTooLarge }
        let box = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: nonce),
            ciphertext: sealed.prefix(ciphertextLength),
            tag: sealed.suffix(tagLength)
        )
        return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }
}

/// XChaCha20-Poly1305 as specified in draft-irtf-cfrg-xchacha-03.
enum XChaCha20Poly1305 {
    static let nonceLength = 24

    static func seal(_ plaintext: Data, key: Data, nonce: Data, authenticating aad: Data = Data()) throws -> Data {
        guard nonce.count == nonceLength else { throw WireGuardCryptoError.invalidNonceLength }
        var subkey = try HChaCha20.deriveKey(key: key, nonce: nonce.prefix(HChaCha20.nonceLength))
        defer { SecretBytes.zero(&subkey) }
        return try ChaCha20Poly1305.seal(plaintext, key: subkey, nonce: innerNonce(nonce), authenticating: aad)
    }

    static func open(_ sealed: Data, key: Data, nonce: Data, authenticating aad: Data = Data()) throws -> Data {
        guard nonce.count == nonceLength else { throw WireGuardCryptoError.invalidNonceLength }
        var subkey = try HChaCha20.deriveKey(key: key, nonce: nonce.prefix(HChaCha20.nonceLength))
        defer { SecretBytes.zero(&subkey) }
        return try ChaCha20Poly1305.open(sealed, key: subkey, nonce: innerNonce(nonce), authenticating: aad)
    }

    private static func innerNonce(_ nonce: Data) -> Data {
        var inner = Data(count: 4)
        inner.append(nonce.suffix(8))
        return inner
    }
}

enum HChaCha20 {
    static let nonceLength = 16

    static func deriveKey(key: Data, nonce: Data) throws -> Data {
        guard key.count == ChaCha20Poly1305.keyLength else { throw WireGuardCryptoError.invalidKeyLength }
        guard nonce.count == nonceLength else { throw WireGuardCryptoError.invalidNonceLength }

        var state: [UInt32] = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]
        state.reserveCapacity(16)
        defer { state.withUnsafeMutableBytes { SecretBytes.zero($0) } }
        for input in [key, nonce] {
            input.withUnsafeBytes { bytes in
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    state.append(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                }
            }
        }

        for _ in 0..<10 {
            quarterRound(&state, 0, 4, 8, 12)
            quarterRound(&state, 1, 5, 9, 13)
            quarterRound(&state, 2, 6, 10, 14)
            quarterRound(&state, 3, 7, 11, 15)
            quarterRound(&state, 0, 5, 10, 15)
            quarterRound(&state, 1, 6, 11, 12)
            quarterRound(&state, 2, 7, 8, 13)
            quarterRound(&state, 3, 4, 9, 14)
        }

        var subkey = Data(capacity: ChaCha20Poly1305.keyLength)
        for index in [0, 1, 2, 3, 12, 13, 14, 15] {
            withUnsafeBytes(of: state[index].littleEndian) { subkey.append(contentsOf: $0) }
        }
        return subkey
    }

    private static func quarterRound(_ v: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        v[a] = v[a] &+ v[b]
        v[d] = rotateLeft(v[d] ^ v[a], by: 16)
        v[c] = v[c] &+ v[d]
        v[b] = rotateLeft(v[b] ^ v[c], by: 12)
        v[a] = v[a] &+ v[b]
        v[d] = rotateLeft(v[d] ^ v[a], by: 8)
        v[c] = v[c] &+ v[d]
        v[b] = rotateLeft(v[b] ^ v[c], by: 7)
    }

    private static func rotateLeft(_ word: UInt32, by count: Int) -> UInt32 {
        (word << count) | (word >> (32 - count))
    }
}
