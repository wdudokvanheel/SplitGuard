// SPDX-License-Identifier: MIT

import Foundation
import WireGuardEngine

public struct PeerConfiguration: Equatable, Sendable {
    public var publicKey: WireGuardPublicKey
    public var presharedKey: WireGuardPresharedKey?
    public var allowedIPs: [IPPrefix]
    public var endpoint: Endpoint?
    public var persistentKeepalive: UInt16?

    public init(
        publicKey: WireGuardPublicKey,
        presharedKey: WireGuardPresharedKey? = nil,
        allowedIPs: [IPPrefix] = [],
        endpoint: Endpoint? = nil,
        persistentKeepalive: UInt16? = nil
    ) {
        self.publicKey = publicKey
        self.presharedKey = presharedKey
        self.allowedIPs = allowedIPs
        self.endpoint = endpoint
        self.persistentKeepalive = persistentKeepalive
    }
}
