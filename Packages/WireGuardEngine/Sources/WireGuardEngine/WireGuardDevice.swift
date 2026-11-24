// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Darwin
import Foundation

final class WireGuardPeer {
    struct State {
        var presharedKey = NoisePresharedKey.zero
        var endpoint: IPEndpoint?
        var persistentKeepaliveInterval: UInt16 = 0

        // Unix nanoseconds for UAPI display. Protocol timers use ProtocolInstant.
        var lastHandshakeUnixNanoseconds: Int64 = 0
        var txBytes: UInt64 = 0
        var rxBytes: UInt64 = 0
        var handshakeLocalIndex: UInt32?
    }

    let publicKey: NoisePublicKey
    let keypairs = SessionKeypairs()
    private let lock = NSLock()
    private var state = State()

    init(publicKey: NoisePublicKey) {
        self.publicKey = publicKey
    }

    /// Lock order is device, peer, keypair slots, then index table or session.
    /// Callers must release peer state before acquiring the device lock.
    func withState<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&state) }
    }

    deinit {
        state.presharedKey.clear()
    }
}

enum UAPIError: Error, Equatable {
    case inputTooLong
    case malformedLine
    case invalidValue(key: String)
    case portInUse

    var code: Int64 {
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
final class WireGuardDevice {
    struct StaticIdentity {
        fileprivate(set) var privateKey = NoisePrivateKey.zero
        fileprivate(set) var publicKey = NoisePublicKey.zero
    }

    private struct PeerSelection {
        var peer: WireGuardPeer?
        let created: Bool
    }

    private static let maxPeers = 1 << 16
    private static let maxScanTokenSize = 64 * 1024

    private let lock = NSLock()
    private var identity = StaticIdentity()
    private var port: UInt16 = 0
    private var mark: UInt32 = 0
    private var peers: [NoisePublicKey: WireGuardPeer] = [:]
    private let allowedIPs = AllowedIPs<WireGuardPeer>()
    let indices = SessionIndexTable<WireGuardPeer>()

    var staticIdentity: StaticIdentity { lock.withLock { identity } }
    var listenPort: UInt16 { lock.withLock { port } }
    var firewallMark: UInt32 { lock.withLock { mark } }

    func peer(for key: NoisePublicKey) -> WireGuardPeer? {
        lock.withLock { peers[key] }
    }

    func peer(for address: IPAddress) -> WireGuardPeer? {
        allowedIPs.lookup(address)
    }

    func ipcSet(_ config: String) throws {
        try lock.withLock {
            var selection: PeerSelection?
            var remaining = config.utf8[...]
            while !remaining.isEmpty {
                // Go ScanLines strips a single CR before LF or EOF. The scanner
                // needs room for the line terminator and caps the raw token at 64 KiB.
                let scan = remaining.prefix(Self.maxScanTokenSize)
                let newline = scan.firstIndex(of: 10)
                guard newline != nil || scan.count < Self.maxScanTokenSize else {
                    throw UAPIError.inputTooLong
                }
                var line = remaining[..<(newline ?? remaining.endIndex)]
                remaining = newline.map { remaining[remaining.index(after: $0)...] }
                    ?? remaining[remaining.endIndex...]
                if line.last == 13 { line = line.dropLast() }
                if line.isEmpty { return }
                guard let equals = line.firstIndex(of: 61) else { throw UAPIError.malformedLine }

                let key = String(decoding: line[..<equals], as: UTF8.self)
                let value = String(decoding: line[line.index(after: equals)...], as: UTF8.self)
                if key == "public_key" {
                    selection = try selectPeer(value[...])
                } else if let selected = selection {
                    selection = try setPeerField(key, value[...], selected)
                } else {
                    try setDeviceField(key, value[...])
                }
            }
        }
    }

    func ipcGet() -> String {
        lock.withLock {
            var result = ""
            if !identity.privateKey.isZero { result += "private_key=\(identity.privateKey.hex)\n" }
            if port != 0 { result += "listen_port=\(port)\n" }
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
                for peer in peers.values {
                    clearHandshakeIndex(for: peer)
                    peer.keypairs.withSlots {
                        $0.current?.expireSending()
                        $0.next?.expireSending()
                    }
                }
            }
        case "listen_port":
            guard let port = parseUnsignedDecimal(value, as: UInt16.self) else { throw invalid }
            self.port = port
        case "fwmark":
            guard let mark = parseUnsignedDecimal(value, as: UInt32.self) else { throw invalid }
            self.mark = mark
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
        guard peers.count < Self.maxPeers else { throw invalid }
        let peer = WireGuardPeer(publicKey: key)
        peers[key] = peer
        return PeerSelection(peer: peer, created: true)
    }

    private func setPeerField(_ key: String, _ value: Substring, _ selected: PeerSelection) throws -> PeerSelection {
        let invalid = UAPIError.invalidValue(key: key)
        let peer = selected.peer
        switch key {
        case "update_only", "remove":
            guard value == "true" else { throw invalid }
            if let peer, key == "remove" || selected.created {
                removePeer(peer.publicKey)
                return PeerSelection(peer: nil, created: selected.created)
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
            peer?.withState { $0.persistentKeepaliveInterval = interval }
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

    private func removePeer(_ publicKey: NoisePublicKey) {
        guard let peer = peers.removeValue(forKey: publicKey) else { return }
        allowedIPs.removeAll(for: peer)
        clearHandshakeIndex(for: peer)
        peer.keypairs.withSlots {
            for keypair in [$0.previous, $0.current, $0.next].compactMap({ $0 }) {
                indices.delete(keypair)
            }
            $0 = SessionKeypairs.Slots()
        }
    }

    private func clearHandshakeIndex(for peer: WireGuardPeer) {
        peer.withState {
            if let index = $0.handshakeLocalIndex {
                indices.deleteHandshake(index, for: peer)
                $0.handshakeLocalIndex = nil
            }
        }
    }

    deinit {
        identity.privateKey.clear()
    }
}
