// SPDX-License-Identifier: MIT

import Foundation
import WireGuardEngine

/// A WireGuard peer endpoint consisting of an IP address or hostname and a UDP port.
public struct Endpoint: Hashable, Codable, CustomStringConvertible, Sendable {
    public enum Host: Hashable, Sendable {
        case ip(IPAddress)
        case name(String)
    }

    public let host: Host
    public let port: UInt16

    public init(host: Host, port: UInt16) {
        self.host = host
        self.port = port
    }

    public init(_ ipEndpoint: IPEndpoint) {
        self.init(host: .ip(ipEndpoint.address), port: ipEndpoint.port)
    }

    public init?(_ text: some StringProtocol) {
        let text = Substring(text)
        guard !text.isEmpty else { return nil }

        if text.utf8.first == 91 { // '['
            let afterOpen = text.utf8.index(after: text.startIndex)
            guard let closeBracket = text.utf8[afterOpen...].firstIndex(of: 93) else {
                return nil
            }
            let afterClose = text.utf8.index(after: closeBracket)
            guard afterClose < text.endIndex, text.utf8[afterClose] == 58 else { // ':'
                return nil
            }
            let hostPart = text[afterOpen..<closeBracket]
            let portPart = text[text.utf8.index(after: afterClose)...]
            guard let port = parseUnsignedDecimal(portPart, as: UInt16.self),
                  port > 0,
                  let address = IPAddress(hostPart),
                  address.isIPv6
            else {
                return nil
            }
            self.init(host: .ip(address), port: port)
        } else {
            guard let colon = text.utf8.firstIndex(of: 58) else { // ':'
                return nil
            }
            let hostPart = text[..<colon]
            let portPart = text[text.utf8.index(after: colon)...]
            guard !hostPart.isEmpty,
                  let port = parseUnsignedDecimal(portPart, as: UInt16.self),
                  port > 0
            else {
                return nil
            }
            if let address = IPAddress(hostPart) {
                guard !address.isIPv6 else { return nil }
                self.init(host: .ip(address), port: port)
            } else {
                guard Self.isValidHostname(hostPart) else { return nil }
                self.init(host: .name(String(hostPart)), port: port)
            }
        }
    }

    public var hostname: String? {
        if case .name(let name) = host {
            return name
        }
        return nil
    }

    public var ipEndpoint: IPEndpoint? {
        if case .ip(let address) = host {
            return IPEndpoint(address: address, port: port)
        }
        return nil
    }

    public var description: String {
        switch host {
        case .ip(let address):
            return address.isIPv6 ? "[\(address)]:\(port)" : "\(address):\(port)"
        case .name(let hostname):
            return "\(hostname):\(port)"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = Endpoint(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid endpoint: \(text)"
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static func isValidHostname(_ host: Substring) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        let trimmed = host.hasSuffix(".") && !host.hasSuffix("..") ? host.dropLast() : host
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."), !trimmed.hasSuffix(".") else {
            return false
        }

        let labels = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }

        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
            for byte in label.utf8 {
                let isUpper = (65...90).contains(byte)
                let isLower = (97...122).contains(byte)
                let isDigit = (48...57).contains(byte)
                let isHyphen = byte == 45
                let isUnderscore = byte == 95
                if !(isUpper || isLower || isDigit || isHyphen || isUnderscore) {
                    return false
                }
            }
        }

        if let lastLabel = labels.last, lastLabel.utf8.allSatisfy({ (48...57).contains($0) }) {
            return false
        }

        return true
    }
}
