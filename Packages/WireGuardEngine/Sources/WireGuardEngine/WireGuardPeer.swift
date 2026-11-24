// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Foundation

final class WireGuardPeer: @unchecked Sendable {
    struct State {
        var presharedKey = NoisePresharedKey.zero
        var endpoint: IPEndpoint?
        var persistentKeepaliveInterval: UInt16 = 0

        // Unix nanoseconds for UAPI display. Protocol timers use ProtocolInstant.
        var lastHandshakeUnixNanoseconds: Int64 = 0
        var txBytes: UInt64 = 0
        var rxBytes: UInt64 = 0
        var handshake = NoiseHandshakeState()
        var cookieGenerator: CookieGenerator
        var running = false
        var roamingDisabled = false
        var lastSentHandshake: ProtocolInstant?
        var handshakeAttempts = 0
        var needAnotherKeepalive = false
        var sentLastMinuteHandshake = false
        var staged = PacketQueue<Data>(capacity: WireGuardDevice.stagedCapacity)

        init(publicKey: NoisePublicKey) {
            cookieGenerator = CookieGenerator(for: publicKey)
        }
    }

    let publicKey: NoisePublicKey
    let keypairs = SessionKeypairs()
    private let lock = NSLock()
    private var state: State

    init(publicKey: NoisePublicKey) {
        self.publicKey = publicKey
        state = State(publicKey: publicKey)
    }

    /// Lock order is device, peer, keypair slots, then index table or session.
    /// Callers must release peer state before acquiring the device lock.
    func withState<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&state) }
    }

    deinit {
        state.presharedKey.clear()
        state.handshake.clearExchange()
        SecretBytes.zero(&state.handshake.staticSharedSecret)
        state.cookieGenerator.clear()
    }
}
