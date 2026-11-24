// SPDX-License-Identifier: MIT

import Foundation

final class WireGuardPeer: @unchecked Sendable {
    struct State {
        var presharedKey = NoisePresharedKey.zero
        var endpoint: IPEndpoint?
        var persistentKeepaliveInterval: UInt16 = 0

        // Unix nanoseconds for UAPI / status display. Protocol timers and health use ProtocolInstant.
        var lastHandshakeUnixNanoseconds: Int64 = 0
        var lastSentUnixNanoseconds: Int64?
        var lastReceivedUnixNanoseconds: Int64?
        var txBytes: UInt64 = 0
        var rxBytes: UInt64 = 0
        var handshake = NoiseHandshakeState()
        var cookieGenerator: CookieGenerator
        var running = false
        var roamingDisabled = false
        var lastSentHandshake: ProtocolInstant?
        var handshakeInitiatedAt: ProtocolInstant?
        var lastInitiationSentAt: ProtocolInstant?
        var handshakeRoundTripNanoseconds: UInt64?
        var handshakeGaveUp = false
        var lastHandshakeInstant: ProtocolInstant?
        var lastAuthenticatedReceivedInstant: ProtocolInstant?
        var lastDataSentInstant: ProtocolInstant?
        var lastReportedHealth: PeerHealth = .idle
        var handshakeAttempts = 0
        var needAnotherKeepalive = false
        var sentLastMinuteHandshake = false
        var staged = PacketQueue<StagedPacket>(capacity: WireGuardDevice.stagedCapacity)

        init(publicKey: NoisePublicKey) {
            cookieGenerator = CookieGenerator(for: publicKey)
        }

        mutating func roam(to source: IPEndpoint) -> Bool {
            guard !roamingDisabled, endpoint != source else { return false }
            endpoint = source
            return true
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
