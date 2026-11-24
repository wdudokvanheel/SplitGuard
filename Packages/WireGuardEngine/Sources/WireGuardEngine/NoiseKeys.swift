// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Foundation

struct NoisePublicKey: Hashable, Sendable {
    private static let byteCount = 32
    static let zero = NoisePublicKey(rawValue: Data(count: byteCount))!
    let rawValue: Data

    init?(rawValue: Data) {
        guard rawValue.count == Self.byteCount else { return nil }
        self.rawValue = rawValue
    }

    init?(hex: Substring) {
        guard let rawValue = decodeKey(hex, byteCount: Self.byteCount) else { return nil }
        self.init(rawValue: rawValue)
    }

    func matches(_ other: Self) -> Bool {
        SecretBytes.equal(rawValue, other.rawValue)
    }

    var isZero: Bool { SecretBytes.isZero(rawValue) }
    var hex: String { encodeKey(rawValue) }
}

struct NoisePrivateKey {
    private static let byteCount = 32
    static var zero: Self { NoisePrivateKey(rawValue: Data(count: byteCount), preservingZero: true)! }
    private(set) var rawValue: Data

    init?(rawValue: Data, preservingZero: Bool = false) {
        guard rawValue.count == Self.byteCount else { return nil }
        var key = rawValue
        if !preservingZero || !SecretBytes.isZero(key) {
            key[key.startIndex] &= 248
            let last = key.index(before: key.endIndex)
            key[last] = (key[last] & 127) | 64
        }
        self.rawValue = key
    }

    init?(hex: Substring, preservingZero: Bool = false) {
        guard var decoded = decodeKey(hex, byteCount: Self.byteCount) else { return nil }
        defer { SecretBytes.zero(&decoded) }
        self.init(rawValue: decoded, preservingZero: preservingZero)
    }

    func matches(_ other: Self) -> Bool {
        SecretBytes.equal(rawValue, other.rawValue)
    }

    private init(clampedKey: Data) { rawValue = clampedKey }

    static func generate() -> Self {
        Self(clampedKey: X25519.generatePrivateKey())
    }

    func publicKey() throws -> NoisePublicKey {
        NoisePublicKey(rawValue: try X25519.publicKey(for: rawValue))!
    }

    mutating func clear() { SecretBytes.zero(&rawValue) }

    var isZero: Bool { SecretBytes.isZero(rawValue) }
    var hex: String { encodeKey(rawValue) }
}

struct NoisePresharedKey {
    private static let byteCount = 32
    static var zero: Self { NoisePresharedKey(rawValue: Data(count: byteCount))! }
    private(set) var rawValue: Data

    init?(rawValue: Data) {
        guard rawValue.count == Self.byteCount else { return nil }
        self.rawValue = rawValue
    }

    init?(hex: Substring) {
        guard let rawValue = decodeKey(hex, byteCount: Self.byteCount) else { return nil }
        self.init(rawValue: rawValue)
    }

    mutating func clear() { SecretBytes.zero(&rawValue) }

    var isZero: Bool { SecretBytes.isZero(rawValue) }
    var hex: String { encodeKey(rawValue) }
}

private func decodeKey(_ hex: Substring, byteCount: Int) -> Data? {
    guard hex.utf8.count == 2 * byteCount else { return nil }
    var bytes = Data(capacity: byteCount)
    var digits = hex.utf8.makeIterator()
    while let high = digits.next(), let low = digits.next() {
        guard let upper = hexNibble(high), let lower = hexNibble(low) else {
            SecretBytes.zero(&bytes)
            return nil
        }
        bytes.append((upper << 4) | lower)
    }
    return bytes
}

private func hexNibble(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: return byte - 48
    case 65...70: return byte - 55
    case 97...102: return byte - 87
    default: return nil
    }
}

private func encodeKey(_ bytes: Data) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var encoded: [UInt8] = []
    encoded.reserveCapacity(2 * bytes.count)
    for byte in bytes {
        encoded.append(digits[Int(byte >> 4)])
        encoded.append(digits[Int(byte & 15)])
    }
    return String(decoding: encoded, as: UTF8.self)
}
