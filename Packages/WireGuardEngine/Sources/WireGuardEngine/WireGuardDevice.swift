// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// Owns the static identity, peer objects, allowed-IP routing and local session indices.
public final class WireGuardDevice: @unchecked Sendable {
    struct StaticIdentity {
        var privateKey = NoisePrivateKey.zero
        var publicKey = NoisePublicKey.zero
    }

    static let maxPeers = 1 << 16

    // Live transitions use the same lock as Noise and configuration updates. The handshake
    // pipeline can use the existing locked Noise methods as part of a larger atomic transition.
    let lock = NSRecursiveLock()
    // Final adapter submissions use separate locks to keep I/O off the device lock.
    // Take these before the device lock, and the transport lock before the tunnel lock.
    let transportSubmission = NSLock()
    let tunnelSubmission = NSLock()
    let io: DeviceIO?
    let events = DeviceEventDispatcher()
    let hookStorage = PacketHookStorage()
    var identity = StaticIdentity()
    var cookieChecker = CookieChecker(for: .zero)
    let protocolNow: () -> ProtocolInstant
    let timestampNow: () -> TAI64N
    var configuredPort: UInt16 = 0
    var boundPort: UInt16 = 0
    var mark: UInt32 = 0
    var peers: [NoisePublicKey: WireGuardPeer] = [:]
    let allowedIPs = AllowedIPs<WireGuardPeer>()
    let indices = SessionIndexTable<WireGuardPeer>()

    init(
        protocolNow: @escaping () -> ProtocolInstant = ProtocolInstant.now,
        timestampNow: @escaping () -> TAI64N = TAI64N.now,
        io: DeviceIO? = nil
    ) {
        self.protocolNow = protocolNow
        self.timestampNow = timestampNow
        self.io = io
        io?.install(on: self)
    }

    public convenience init(tunnel: TunnelDevice, transport: UDPTransport) throws {
        try self.init(io: DeviceIO(tunnel: tunnel, transport: transport))
    }

    var staticIdentity: StaticIdentity { lock.withLock { identity } }
    public var listenPort: UInt16 { lock.withLock { io == nil ? configuredPort : boundPort } }
    var firewallMark: UInt32 { lock.withLock { mark } }

    func peer(for key: NoisePublicKey) -> WireGuardPeer? {
        lock.withLock { peers[key] }
    }

    func peer(for address: IPAddress) -> WireGuardPeer? {
        allowedIPs.lookup(address)
    }

    func removePeer(_ publicKey: NoisePublicKey) {
        guard let peer = peers.removeValue(forKey: publicKey) else { return }
        allowedIPs.removeAll(for: peer)
        stopPeer(peer)
        peer.withState { state in
            SecretBytes.zero(&state.handshake.staticSharedSecret)
            state.presharedKey.clear()
            state.cookieGenerator.clear()
        }
    }

    func clearHandshake(_ handshake: inout NoiseHandshakeState, for peer: WireGuardPeer) {
        if let index = handshake.localIndex { indices.deleteHandshake(index, for: peer) }
        handshake.clearExchange()
    }

    deinit {
        close()
        identity.privateKey.clear()
        cookieChecker.clear()
    }
}
