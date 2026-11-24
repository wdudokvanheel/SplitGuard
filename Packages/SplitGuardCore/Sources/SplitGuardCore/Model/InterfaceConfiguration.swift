// SPDX-License-Identifier: MIT

import Foundation
import WireGuardEngine

public struct InterfaceConfiguration: Equatable, Sendable {
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
}
