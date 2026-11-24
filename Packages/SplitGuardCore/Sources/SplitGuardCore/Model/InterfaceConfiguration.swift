// SPDX-License-Identifier: MIT

import Foundation
import WireGuardEngine

public struct InterfaceConfiguration: Equatable, Sendable {
    /// An explicitly set MTU must fit in one WireGuard transport packet.
    public static let supportedMTURange = 576...WireGuardDevice.maxContentSize

    public var privateKey: WireGuardPrivateKey
    public var addresses: [InterfaceAddress]
    public var listenPort: UInt16?
    public var mtu: UInt16?
    public var dnsServers: [IPAddress]
    public var dnsSearch: [String]

    public init(
        privateKey: WireGuardPrivateKey,
        addresses: [InterfaceAddress] = [],
        listenPort: UInt16? = nil,
        mtu: UInt16? = nil,
        dnsServers: [IPAddress] = [],
        dnsSearch: [String] = []
    ) {
        self.privateKey = privateKey
        self.addresses = addresses
        self.listenPort = listenPort
        self.mtu = mtu
        self.dnsServers = dnsServers
        self.dnsSearch = dnsSearch
    }

    public static func isSupportedMTU(_ mtu: UInt16) -> Bool {
        mtu == 0 || supportedMTURange.contains(Int(mtu))
    }

    public func validateMTU() throws {
        if let mtu, !Self.isSupportedMTU(mtu) {
            throw TunnelProfileError.unsupportedMTU(mtu)
        }
    }

    static func invalidMTUDescription(_ value: String) -> String {
        let range = supportedMTURange
        return "Interface MTU \"\(value)\" is invalid. Use \(range.lowerBound)–\(range.upperBound), 0 for Automatic, or omit the MTU."
    }
}
