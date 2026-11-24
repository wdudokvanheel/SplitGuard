// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import CryptoKit
import Foundation

enum X25519 {
    static let keyLength = 32

    static func generatePrivateKey() -> Data {
        var bytes = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        // The Go reference stores generated private keys in their clamped form.
        bytes[0] &= 248
        bytes[31] = (bytes[31] & 127) | 64
        return bytes
    }

    static func publicKey(for privateKey: Data) throws -> Data {
        guard privateKey.count == keyLength else { throw WireGuardCryptoError.invalidKeyLength }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation
    }

    static func sharedSecret(privateKey: Data, publicKey: Data) throws -> Data {
        guard privateKey.count == keyLength, publicKey.count == keyLength else {
            throw WireGuardCryptoError.invalidKeyLength
        }
        let local = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let shared: SharedSecret
        do {
            let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
            shared = try local.sharedSecretFromKeyAgreement(with: remote)
        } catch {
            // CryptoKit may reject a low-order input before returning a secret.
            throw WireGuardCryptoError.invalidSharedSecret
        }
        var bytes = shared.withUnsafeBytes { Data($0) }
        guard !SecretBytes.isZero(bytes) else {
            SecretBytes.zero(&bytes)
            throw WireGuardCryptoError.invalidSharedSecret
        }
        return bytes
    }
}
