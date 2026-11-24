// SPDX-License-Identifier: MIT

import Foundation
import WireGuardEngine

/// An interface IP address paired with its CIDR prefix length, preserving host bits.
public struct InterfaceAddress: Hashable, Codable, CustomStringConvertible, Sendable {
    public let address: IPAddress
    public let prefixLength: UInt8
    public let network: IPPrefix

    public init?(address: IPAddress, prefixLength: UInt8) {
        guard let network = IPPrefix(address: address, length: Int(prefixLength)) else {
            return nil
        }
        self.address = address
        self.prefixLength = prefixLength
        self.network = network
    }

    public init?(_ text: some StringProtocol) {
        let text = Substring(text)
        guard !text.isEmpty else { return nil }

        if let slash = text.utf8.firstIndex(of: 47) {
            let addressPart = text[..<slash]
            let prefixPart = text[text.utf8.index(after: slash)...]
            guard prefixPart.utf8.count == 1 || prefixPart.utf8.first != 48,
                  let prefixLength = parseUnsignedDecimal(prefixPart, as: UInt8.self),
                  let address = IPAddress(addressPart)
            else {
                return nil
            }
            self.init(address: address, prefixLength: prefixLength)
        } else {
            guard let address = IPAddress(text) else { return nil }
            let defaultPrefix: UInt8 = address.isIPv6 ? 128 : 32
            self.init(address: address, prefixLength: defaultPrefix)
        }
    }

    /// Dotted-decimal subnet mask for IPv4 addresses; `nil` for IPv6 addresses.
    public var ipv4SubnetMask: IPAddress? {
        network.ipv4SubnetMask
    }

    public var description: String {
        "\(address)/\(prefixLength)"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = InterfaceAddress(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid interface address: \(text)"
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public extension IPPrefix {
    /// Dotted-decimal subnet mask for IPv4 prefixes; `nil` for IPv6 prefixes.
    var ipv4SubnetMask: IPAddress? {
        guard !address.isIPv6 else { return nil }
        let mask: UInt32 = length == 0 ? 0 : (~UInt32(0) << (32 - length))
        return IPAddress(bytes: [
            UInt8(truncatingIfNeeded: mask >> 24),
            UInt8(truncatingIfNeeded: mask >> 16),
            UInt8(truncatingIfNeeded: mask >> 8),
            UInt8(truncatingIfNeeded: mask)
        ])
    }
}

func parseUnsignedDecimal<T: FixedWidthInteger & UnsignedInteger>(
    _ text: Substring,
    as _: T.Type
) -> T? {
    guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else {
        return nil
    }
    return T(text, radix: 10)
}
