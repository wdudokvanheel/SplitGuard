// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Darwin
import Foundation

public enum UAPIError: Error, Equatable, Sendable {
    case inputTooLong
    case malformedLine
    case invalidValue(key: String)
    case portInUse

    public var code: Int64 {
        switch self {
        case .inputTooLong: return -Int64(EIO)
        case .malformedLine: return -Int64(EPROTO)
        case .invalidValue: return -Int64(EINVAL)
        case .portInUse: return -Int64(EADDRINUSE)
        }
    }
}

/// Owns the static identity, peer objects, allowed-IP routing and local session indices.
/// UAPI applies directly to this state, one line at a time, including on errors.
public final class WireGuardDevice: @unchecked Sendable {
    struct StaticIdentity {
        fileprivate(set) var privateKey = NoisePrivateKey.zero
        fileprivate(set) var publicKey = NoisePublicKey.zero
    }

    private struct PeerSelection {
        var peer: WireGuardPeer?
        let created: Bool
        var keepaliveEnabled = false
        var ignoredKeepaliveInterval: UInt16 = 0
    }

    private static let maxPeers = 1 << 16
    private static let maxScanTokenSize = 64 * 1024

    // Live transitions use the same lock as Noise and UAPI. The handshake pipeline
    // can use the existing locked Noise methods as part of a larger atomic transition.
    let lock = NSRecursiveLock()
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

    public func ipcSet(_ config: String) throws {
        if let io {
            try io.withHandshakeLane { try applyConfiguration(config) }
        } else {
            try applyConfiguration(config)
        }
    }

    private func applyConfiguration(_ config: String) throws {
        try lock.withLock {
            var selection: PeerSelection?
            var remaining = config.utf8[...]
            while !remaining.isEmpty {
                // Go ScanLines strips a single CR before LF or EOF. The scanner
                // needs room for the line terminator and caps the raw token at 64 KiB.
                let scan = remaining.prefix(Self.maxScanTokenSize)
                let newline = scan.firstIndex(of: 10)
                guard newline != nil || scan.count < Self.maxScanTokenSize else {
                    finishConfig(selection)
                    throw UAPIError.inputTooLong
                }
                var line = remaining[..<(newline ?? remaining.endIndex)]
                remaining = newline.map { remaining[remaining.index(after: $0)...] }
                    ?? remaining[remaining.endIndex...]
                if line.last == 13 { line = line.dropLast() }
                if line.isEmpty { break }
                guard let equals = line.firstIndex(of: 61) else { throw UAPIError.malformedLine }

                let key = String(decoding: line[..<equals], as: UTF8.self)
                let value = String(decoding: line[line.index(after: equals)...], as: UTF8.self)
                if key == "public_key" {
                    finishConfig(selection)
                    let keepaliveEnabled = selection?.keepaliveEnabled ?? false
                    selection = try selectPeer(value[...])
                    // The Go parser retains pkaOn until the next keepalive field.
                    selection?.keepaliveEnabled = keepaliveEnabled
                } else if let selected = selection {
                    selection = try setPeerField(key, value[...], selected)
                } else {
                    try setDeviceField(key, value[...])
                }
            }
            finishConfig(selection)
        }
    }

    private func finishConfig(_ selection: PeerSelection?) {
        guard let io, let selection, let peer = selection.peer else { return }
        if selection.created {
            peer.withState { $0.roamingDisabled = io.brokenRoaming && $0.endpoint != nil }
        }
        if io.state == .up {
            startPeer(peer)
            if selection.keepaliveEnabled { sendKeepalive(peer) }
            requestStagedDrain(peer)
        }
    }

    public func ipcGet() -> String {
        lock.withLock {
            var result = ""
            if !identity.privateKey.isZero { result += "private_key=\(identity.privateKey.hex)\n" }
            let activePort = io == nil ? configuredPort : boundPort
            if activePort != 0 { result += "listen_port=\(activePort)\n" }
            if mark != 0 { result += "fwmark=\(mark)\n" }

            // Go map iteration leaves cross-peer order unspecified.
            let orderedPeers = peers.values.sorted {
                $0.publicKey.rawValue.lexicographicallyPrecedes($1.publicKey.rawValue)
            }
            for peer in orderedPeers {
                peer.withState { state in
                    let nanosecondsPerSecond: Int64 = 1_000_000_000
                    let handshake = state.lastHandshakeUnixNanoseconds
                    result += "public_key=\(peer.publicKey.hex)\n"
                    result += "preshared_key=\(state.presharedKey.hex)\n"
                    result += "protocol_version=1\n"
                    if let endpoint = state.endpoint { result += "endpoint=\(endpoint)\n" }
                    result += "last_handshake_time_sec=\(handshake / nanosecondsPerSecond)\n"
                    result += "last_handshake_time_nsec=\(handshake % nanosecondsPerSecond)\n"
                    result += "tx_bytes=\(state.txBytes)\n"
                    result += "rx_bytes=\(state.rxBytes)\n"
                    result += "persistent_keepalive_interval=\(state.persistentKeepaliveInterval)\n"
                }
                for prefix in allowedIPs.prefixes(for: peer) {
                    result += "allowed_ip=\(prefix)\n"
                }
            }
            return result
        }
    }

    private func setDeviceField(_ key: String, _ value: Substring) throws {
        let invalid = UAPIError.invalidValue(key: key)
        switch key {
        case "private_key":
            guard let privateKey = NoisePrivateKey(hex: value, preservingZero: true) else { throw invalid }
            if !identity.privateKey.matches(privateKey) {
                guard let publicKey = try? privateKey.publicKey() else { throw invalid }
                removePeer(publicKey)
                identity.privateKey.clear()
                identity = StaticIdentity(privateKey: privateKey, publicKey: publicKey)
                cookieChecker.clear()
                cookieChecker = CookieChecker(for: publicKey)
                for peer in peers.values {
                    peer.withState { state in
                        clearHandshake(&state.handshake, for: peer)
                        state.lastSentHandshake = nil
                        state.handshake.precompute(privateKey: privateKey, remote: peer.publicKey)
                        peer.keypairs.withSlots {
                            $0.current?.expireSending()
                            $0.next?.expireSending()
                        }
                    }
                }
            }
        case "listen_port":
            guard let port = parseUnsignedDecimal(value, as: UInt16.self) else { throw invalid }
            configuredPort = port
            if let io {
                do { try rebindLocked(io) } catch { throw UAPIError.portInUse }
            }
        case "fwmark":
            guard let mark = parseUnsignedDecimal(value, as: UInt32.self) else { throw invalid }
            guard self.mark != mark else { return }
            self.mark = mark
            if let io {
                if io.state == .up {
                    do { try io.transport.setFirewallMark(mark) } catch { throw UAPIError.portInUse }
                }
                clearEndpointSources(io)
            }
        case "replace_peers":
            guard value == "true" else { throw invalid }
            for publicKey in Array(peers.keys) {
                removePeer(publicKey)
            }
        default:
            throw invalid
        }
    }

    private func selectPeer(_ value: Substring) throws -> PeerSelection {
        let invalid = UAPIError.invalidValue(key: "public_key")
        guard let key = NoisePublicKey(hex: value) else { throw invalid }
        if identity.publicKey.matches(key) { return PeerSelection(peer: nil, created: false) }
        if let peer = peers[key] { return PeerSelection(peer: peer, created: false) }
        guard io?.state != .closed, peers.count < Self.maxPeers else { throw invalid }
        let peer = WireGuardPeer(publicKey: key)
        peer.withState { $0.handshake.precompute(privateKey: identity.privateKey, remote: key) }
        peers[key] = peer
        return PeerSelection(peer: peer, created: true)
    }

    private func setPeerField(_ key: String, _ value: Substring, _ selected: PeerSelection) throws -> PeerSelection {
        let invalid = UAPIError.invalidValue(key: key)
        var selected = selected
        let peer = selected.peer
        switch key {
        case "update_only", "remove":
            guard value == "true" else { throw invalid }
            if let peer, key == "remove" || selected.created {
                removePeer(peer.publicKey)
                return PeerSelection(peer: nil, created: selected.created, keepaliveEnabled: selected.keepaliveEnabled)
            }
        case "preshared_key":
            guard let preshared = NoisePresharedKey(hex: value) else { throw invalid }
            peer?.withState {
                $0.presharedKey.clear()
                $0.presharedKey = preshared
            }
        case "endpoint":
            guard let endpoint = IPEndpoint(value) else { throw invalid }
            peer?.withState { $0.endpoint = endpoint }
        case "persistent_keepalive_interval":
            guard let interval = parseUnsignedDecimal(value, as: UInt16.self) else { throw invalid }
            if let peer {
                selected.keepaliveEnabled = peer.withState {
                    let wasDisabled = $0.persistentKeepaliveInterval == 0
                    $0.persistentKeepaliveInterval = interval
                    return wasDisabled && interval != 0
                }
            } else {
                selected.keepaliveEnabled = selected.ignoredKeepaliveInterval == 0 && interval != 0
                selected.ignoredKeepaliveInterval = interval
            }
        case "replace_allowed_ips":
            guard value == "true" else { throw invalid }
            if let peer { allowedIPs.removeAll(for: peer) }
        case "allowed_ip":
            guard let prefix = IPPrefix(value) else { throw invalid }
            if let peer { allowedIPs.insert(prefix, for: peer) }
        case "protocol_version":
            guard value == "1" else { throw invalid }
        default:
            throw invalid
        }
        return selected
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
