// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Foundation

/// The HMAC and HKDF constructions in wireguard-go device/noise-helpers.go.
enum NoiseKDF {
    static func hmac(key: Data, _ parts: Data...) -> Data {
        authenticate(key: key, parts: parts)
    }

    static func kdf1(key: Data, input: Data) -> Data {
        var prk = hmac(key: key, input)
        defer { SecretBytes.zero(&prk) }
        return hmac(key: prk, Data([1]))
    }

    static func kdf2(key: Data, input: Data) -> (Data, Data) {
        var prk = hmac(key: key, input)
        defer { SecretBytes.zero(&prk) }
        let first = hmac(key: prk, Data([1]))
        let second = hmac(key: prk, first, Data([2]))
        return (first, second)
    }

    static func kdf3(key: Data, input: Data) -> (Data, Data, Data) {
        var prk = hmac(key: key, input)
        defer { SecretBytes.zero(&prk) }
        let first = hmac(key: prk, Data([1]))
        let second = hmac(key: prk, first, Data([2]))
        let third = hmac(key: prk, second, Data([3]))
        return (first, second, third)
    }

    private static func authenticate(key: Data, parts: [Data]) -> Data {
        var pad = Data(count: BLAKE2s.blockLength)
        defer { SecretBytes.zero(&pad) }
        if key.count > BLAKE2s.blockLength {
            var hashedKey = BLAKE2s.hash(key)
            pad.replaceSubrange(0..<hashedKey.count, with: hashedKey)
            SecretBytes.zero(&hashedKey)
        } else {
            pad.replaceSubrange(0..<key.count, with: key)
        }

        xor(&pad, with: 0x36)
        var inner = BLAKE2s.hash(parts: [pad] + parts)
        defer { SecretBytes.zero(&inner) }
        xor(&pad, with: 0x36 ^ 0x5c)
        return BLAKE2s.hash(pad, inner)
    }

    private static func xor(_ bytes: inout Data, with value: UInt8) {
        bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for index in buffer.indices {
                buffer[index] ^= value
            }
        }
    }
}
