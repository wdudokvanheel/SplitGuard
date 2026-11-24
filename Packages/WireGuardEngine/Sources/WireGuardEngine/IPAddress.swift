// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Darwin
import Foundation

/// Network-order address bits. IPv4-mapped IPv6 addresses retain their IPv6 family.
public struct IPAddress: Hashable, Codable, CustomStringConvertible, Sendable {
    public let isIPv6: Bool
    private let high: UInt64
    private let low: UInt64
    private let zone: [UInt8]

    var bitCount: Int { isIPv6 ? 128 : 32 }

    public init?(bytes: some Collection<UInt8>) {
        self.init(bytes: bytes, zoneID: nil)
    }

    /// Create an address from BSD socket bytes and an optional IPv6 scope identifier.
    public init?(bytes: some Collection<UInt8>, zoneID: String?) {
        switch bytes.count {
        case 4 where zoneID == nil:
            self.init(isIPv6: false, high: 0, low: Self.networkWord(bytes))
        case 16:
            self.init(
                isIPv6: true, high: Self.networkWord(bytes.prefix(8)), low: Self.networkWord(bytes.suffix(8)),
                zone: zoneID.map { Array($0.utf8) } ?? []
            )
        default:
            return nil
        }
    }

    public init?(_ text: some StringProtocol) {
        let text = Substring(text)
        let ipv6 = text.utf8.contains(58)
        var host = text.utf8[...]
        var zone: [UInt8] = []
        if ipv6, let separator = host.firstIndex(of: 37) {
            zone = Array(host[host.index(after: separator)...])
            guard !zone.isEmpty else { return nil }
            host = host[..<separator]
        }

        if ipv6 {
            // Darwin's inet_pton accepts extra leading zeros in hexadecimal groups
            // and IPv4 fields. Apply netip's stricter field rules before converting.
            let fields = host.split(separator: 58, omittingEmptySubsequences: false)
            guard let tail = fields.last else { return nil }
            let embeddedIPv4 = tail.contains(46)
            let hexFields = embeddedIPv4 ? fields.dropLast() : fields[...]
            guard hexFields.allSatisfy({ field in
                field.count <= 4 && field.allSatisfy {
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                }
            }), !embeddedIPv4 || Self.ipv4Bytes(tail) != nil else { return nil }

            var address = in6_addr()
            let presentation = String(decoding: host, as: UTF8.self)
            guard inet_pton(AF_INET6, presentation, &address) == 1 else { return nil }
            self = withUnsafeBytes(of: address) { IPAddress(bytes: $0)! }.withZone(zone)
        } else {
            guard let bytes = Self.ipv4Bytes(host) else { return nil }
            self.init(bytes: bytes)
        }
    }

    private init(isIPv6: Bool, high: UInt64, low: UInt64, zone: [UInt8] = []) {
        self.isIPv6 = isIPv6
        self.high = high
        self.low = low
        self.zone = zone
    }

    private static func ipv4Bytes(_ host: Substring.UTF8View) -> [UInt8]? {
        let fields = host.split(separator: 46, omittingEmptySubsequences: false)
        guard fields.count == 4 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for field in fields {
            guard (1...3).contains(field.count), field.count == 1 || field.first != 48,
                  let value = parseUnsignedDecimal(String(decoding: field, as: UTF8.self)[...], as: UInt8.self)
            else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    public var zoneID: String? { zone.isEmpty ? nil : String(decoding: zone, as: UTF8.self) }

    private func withZone(_ zone: [UInt8]) -> IPAddress {
        IPAddress(isIPv6: isIPv6, high: high, low: low, zone: zone)
    }

    private static func networkWord(_ bytes: some Sequence<UInt8>) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    public var bytes: [UInt8] {
        if isIPv6 {
            return withUnsafeBytes(of: high.bigEndian) { Array($0) }
                + withUnsafeBytes(of: low.bigEndian) { Array($0) }
        }
        return withUnsafeBytes(of: UInt32(low).bigEndian) { Array($0) }
    }

    func commonBits(with other: IPAddress) -> Int {
        precondition(isIPv6 == other.isIPv6)
        if !isIPv6 {
            return UInt32(low ^ other.low).leadingZeroBitCount
        }
        let highDifference = high ^ other.high
        if highDifference != 0 {
            return highDifference.leadingZeroBitCount
        }
        return 64 + (low ^ other.low).leadingZeroBitCount
    }

    /// Select a trie branch from the most significant bit onward.
    func bit(at index: Int) -> Int {
        precondition((0..<bitCount).contains(index))
        let shift = bitCount - index - 1
        let word = shift >= 64 ? high : low
        return Int((word >> (shift % 64)) & 1)
    }

    fileprivate func masked(to length: Int) -> IPAddress {
        if !isIPv6 {
            return IPAddress(isIPv6: false, high: 0, low: (low >> (32 - length)) << (32 - length))
        }
        if length < 64 {
            return IPAddress(isIPv6: true, high: (high >> (64 - length)) << (64 - length), low: 0)
        }
        return IPAddress(isIPv6: true, high: high, low: (low >> (128 - length)) << (128 - length))
    }

    public var description: String {
        let suffix = zoneID.map { "%" + $0 } ?? ""
        if !isIPv6 {
            return Self.dottedDecimal(bytes[...])
        }
        if high == 0 && low >> 32 == 0xffff {
            return "::ffff:" + Self.dottedDecimal(bytes.suffix(4)) + suffix
        }

        // Match netip.String: compress the first longest run of two or more zero fields.
        let fields = [high, low].flatMap { word in
            [48, 32, 16, 0].map { UInt16(truncatingIfNeeded: word >> $0) }
        }
        var bestStart = 0
        var bestLength = 1
        var runStart = 0
        for index in fields.indices {
            if fields[index] != 0 {
                runStart = index + 1
            } else if index - runStart + 1 > bestLength {
                bestStart = runStart
                bestLength = index - runStart + 1
            }
        }
        let hex = fields.map { String($0, radix: 16) }
        guard bestLength > 1 else { return hex.joined(separator: ":") + suffix }
        return hex[..<bestStart].joined(separator: ":") + "::"
            + hex[(bestStart + bestLength)...].joined(separator: ":") + suffix
    }

    private static func dottedDecimal(_ bytes: ArraySlice<UInt8>) -> String {
        bytes.map { String($0) }.joined(separator: ".")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = IPAddress(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid IP address: \(text)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct IPPrefix: Hashable, Codable, CustomStringConvertible, Sendable {
    public let address: IPAddress
    public let length: Int

    public init?(address: IPAddress, length: Int) {
        guard address.zoneID == nil, (0...address.bitCount).contains(length) else { return nil }
        self.address = address.masked(to: length)
        self.length = length
    }

    public init?(_ text: some StringProtocol) {
        let text = Substring(text)
        guard let slash = text.utf8.lastIndex(of: 47) else { return nil }
        let bits = text[text.utf8.index(after: slash)...]
        // The netip version used by the app accepts only canonical decimal prefix lengths.
        guard bits.utf8.count == 1 || bits.utf8.first != 48,
              let length = parseUnsignedDecimal(bits, as: UInt8.self),
              let address = IPAddress(text[..<slash]) else { return nil }
        self.init(address: address, length: Int(length))
    }

    public func contains(_ candidate: IPAddress) -> Bool {
        candidate.isIPv6 == address.isIPv6 && address.commonBits(with: candidate) >= length
    }

    public var description: String { "\(address)/\(length)" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = IPPrefix(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid IP prefix: \(text)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct IPEndpoint: Hashable, Codable, CustomStringConvertible, Sendable {
    public let address: IPAddress
    public let port: UInt16

    public init(address: IPAddress, port: UInt16) {
        self.address = address
        self.port = port
    }

    public init?(_ text: some StringProtocol) {
        let text = Substring(text)
        guard let colon = text.utf8.lastIndex(of: 58),
              let port = parseUnsignedDecimal(text[text.utf8.index(after: colon)...], as: UInt16.self)
        else { return nil }
        var host = text.utf8[..<colon]
        let bracketed = host.first == 91
        if bracketed {
            guard host.count >= 2, host.last == 93 else { return nil }
            host = host.dropFirst().dropLast()
        }
        guard let address = IPAddress(String(decoding: host, as: UTF8.self)[...]),
              address.isIPv6 == bracketed else { return nil }
        self.init(address: address, port: port)
    }

    /// Matches netip.AddrPort.MarshalBinary, used by the Go cookie code.
    var destinationBytes: [UInt8] {
        var result = address.bytes
        if let zoneID = address.zoneID {
            result.append(contentsOf: zoneID.utf8)
        }
        withUnsafeBytes(of: port.littleEndian) { result.append(contentsOf: $0) }
        return result
    }

    public var description: String {
        address.isIPv6 ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = IPEndpoint(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid IP endpoint: \(text)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

func parseUnsignedDecimal<T: FixedWidthInteger & UnsignedInteger>(_ text: Substring, as: T.Type) -> T? {
    guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return T(text, radix: 10)
}

enum IPHeader {
    static let ipv4TotalLength = 2
    static let ipv4Source = 12
    static let ipv4Destination = 16
    static let ipv6PayloadLength = 4
    static let ipv6Source = 8
    static let ipv6Destination = 24
}
