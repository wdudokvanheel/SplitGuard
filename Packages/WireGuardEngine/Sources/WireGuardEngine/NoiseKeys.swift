// SPDX-License-Identifier: MIT

import Foundation

public struct WireGuardPublicKey: Hashable, Codable, Sendable, CustomStringConvertible {
    private static let byteCount = 32
    static let zero = WireGuardPublicKey(rawValue: Data(count: byteCount))!
    public let rawValue: Data

    public init?(rawValue: Data) {
        guard rawValue.count == Self.byteCount else { return nil }
        self.rawValue = rawValue
    }

    public init?(hex: some StringProtocol) {
        guard let rawValue = decodeKey(Substring(hex), byteCount: Self.byteCount) else { return nil }
        self.init(rawValue: rawValue)
    }

    public init?(base64: String) {
        guard let rawValue = Data(base64Encoded: base64), rawValue.count == Self.byteCount else { return nil }
        self.init(rawValue: rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard let key = WireGuardPublicKey(base64: encoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid base64 WireGuard public key"
            )
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base64)
    }

    func matches(_ other: Self) -> Bool {
        SecretBytes.equal(rawValue, other.rawValue)
    }

    var isZero: Bool { SecretBytes.isZero(rawValue) }
    public var hex: String { encodeKey(rawValue) }
    public var base64: String { rawValue.base64EncodedString() }
    public var description: String { base64 }
}

public struct WireGuardPrivateKey: Equatable, Sendable {
    private static let byteCount = 32
    static var zero: Self { WireGuardPrivateKey(rawValue: Data(count: byteCount), preservingZero: true)! }
    public private(set) var rawValue: Data

    public init?(rawValue: Data, preservingZero: Bool = false) {
        guard rawValue.count == Self.byteCount else { return nil }
        if SecretBytes.isZero(rawValue) {
            guard preservingZero else { return nil }
            self.rawValue = rawValue
            return
        }
        var key = rawValue
        key[key.startIndex] &= 248
        let last = key.index(before: key.endIndex)
        key[last] = (key[last] & 127) | 64
        self.rawValue = key
    }

    public init?(hex: some StringProtocol, preservingZero: Bool = false) {
        guard var decoded = decodeKey(Substring(hex), byteCount: Self.byteCount) else { return nil }
        defer { SecretBytes.zero(&decoded) }
        self.init(rawValue: decoded, preservingZero: preservingZero)
    }

    public init?(base64: String) {
        guard var decoded = Data(base64Encoded: base64), decoded.count == Self.byteCount else { return nil }
        defer { SecretBytes.zero(&decoded) }
        self.init(rawValue: decoded, preservingZero: false)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        SecretBytes.equal(lhs.rawValue, rhs.rawValue)
    }

    func matches(_ other: Self) -> Bool {
        SecretBytes.equal(rawValue, other.rawValue)
    }

    private init(clampedKey: Data) { rawValue = clampedKey }

    public static func generate() -> Self {
        Self(clampedKey: X25519.generatePrivateKey())
    }

    public func publicKey() throws -> WireGuardPublicKey {
        WireGuardPublicKey(rawValue: try X25519.publicKey(for: rawValue))!
    }

    public mutating func clear() { SecretBytes.zero(&rawValue) }

    var isZero: Bool { SecretBytes.isZero(rawValue) }
    public var hex: String { encodeKey(rawValue) }
    public var base64: String { rawValue.base64EncodedString() }
}

public struct WireGuardPresharedKey: Equatable, Sendable {
    private static let byteCount = 32
    static var zero: Self { WireGuardPresharedKey(rawValue: Data(count: byteCount))! }
    public private(set) var rawValue: Data

    public init?(rawValue: Data) {
        guard rawValue.count == Self.byteCount else { return nil }
        self.rawValue = rawValue
    }

    public init?(hex: some StringProtocol) {
        guard let rawValue = decodeKey(Substring(hex), byteCount: Self.byteCount) else { return nil }
        self.init(rawValue: rawValue)
    }

    public init?(base64: String) {
        guard let rawValue = Data(base64Encoded: base64), rawValue.count == Self.byteCount else { return nil }
        self.init(rawValue: rawValue)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        SecretBytes.equal(lhs.rawValue, rhs.rawValue)
    }

    public mutating func clear() { SecretBytes.zero(&rawValue) }

    var isZero: Bool { SecretBytes.isZero(rawValue) }
    public var hex: String { encodeKey(rawValue) }
    public var base64: String { rawValue.base64EncodedString() }
}

typealias NoisePublicKey = WireGuardPublicKey
typealias NoisePrivateKey = WireGuardPrivateKey
typealias NoisePresharedKey = WireGuardPresharedKey

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
