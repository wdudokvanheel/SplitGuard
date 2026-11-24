// SPDX-License-Identifier: MIT

import Foundation

public struct DevicePeerConfiguration: Equatable, Sendable {
    public var publicKey: WireGuardPublicKey
    public var presharedKey: WireGuardPresharedKey?
    public var endpoint: IPEndpoint?
    public var allowedIPs: [IPPrefix]
    public var persistentKeepalive: UInt16

    public init(
        publicKey: WireGuardPublicKey,
        presharedKey: WireGuardPresharedKey? = nil,
        endpoint: IPEndpoint? = nil,
        allowedIPs: [IPPrefix] = [],
        persistentKeepalive: UInt16 = 0
    ) {
        self.publicKey = publicKey
        self.presharedKey = presharedKey
        self.endpoint = endpoint
        self.allowedIPs = allowedIPs
        self.persistentKeepalive = persistentKeepalive
    }
}

public struct DeviceConfiguration: Equatable, Sendable {
    public var privateKey: WireGuardPrivateKey
    public var listenPort: UInt16?
    public var firewallMark: UInt32?
    public var peers: [DevicePeerConfiguration]

    public init(
        privateKey: WireGuardPrivateKey,
        listenPort: UInt16? = nil,
        firewallMark: UInt32? = nil,
        peers: [DevicePeerConfiguration] = []
    ) {
        self.privateKey = privateKey
        self.listenPort = listenPort
        self.firewallMark = firewallMark
        self.peers = peers
    }
}

public enum DeviceConfigurationError: Error, Equatable, Sendable {
    case deviceClosed
    case invalidPrivateKey
    case duplicatePeer(WireGuardPublicKey)
    case peerMatchesDeviceKey(WireGuardPublicKey)
    case tooManyPeers
    case portInUse
}

extension WireGuardDevice {
    /// Atomically validates and diffs `configuration` against the running device state.
    ///
    /// Validation runs completely before any state mutation. Existing peers that remain
    /// present retain their `WireGuardPeer` instance, active `SessionKeypairs`, counters,
    /// handshake timestamps, and health state.
    public func apply(_ configuration: DeviceConfiguration) throws {
        if let io {
            try io.withHandshakeLane { try applyTypedConfiguration(configuration) }
        } else {
            try applyTypedConfiguration(configuration)
        }
    }

    /// Updates endpoints in place for existing peers without touching sessions, keys, or allowed IPs.
    public func updateEndpoints(_ endpoints: [WireGuardPublicKey: IPEndpoint?]) {
        if let io {
            io.withHandshakeLane { updateEndpointsLocked(endpoints) }
        } else {
            updateEndpointsLocked(endpoints)
        }
    }

    private func applyTypedConfiguration(_ configuration: DeviceConfiguration) throws {
        try lock.withLock {
            // 1. Validate everything up front before mutating any state.
            if io?.state == .closed {
                throw DeviceConfigurationError.deviceClosed
            }
            guard !configuration.privateKey.isZero,
                  let publicKey = try? configuration.privateKey.publicKey() else {
                throw DeviceConfigurationError.invalidPrivateKey
            }
            guard configuration.peers.count <= Self.maxPeers else {
                throw DeviceConfigurationError.tooManyPeers
            }

            var seenKeys = Set<WireGuardPublicKey>()
            seenKeys.reserveCapacity(configuration.peers.count)
            for peerConfig in configuration.peers {
                if peerConfig.publicKey.matches(publicKey) {
                    throw DeviceConfigurationError.peerMatchesDeviceKey(peerConfig.publicKey)
                }
                if !seenKeys.insert(peerConfig.publicKey).inserted {
                    throw DeviceConfigurationError.duplicatePeer(peerConfig.publicKey)
                }
            }

            // 2. Apply listen port & firewall mark first so bind/mark failures roll back cleanly
            //    without leaving identity or peers half-mutated.
            let targetPort = configuration.listenPort ?? 0
            let previousConfiguredPort = configuredPort
            let previousBoundPort = boundPort
            let portChanged = targetPort != previousConfiguredPort
            if portChanged {
                configuredPort = targetPort
                if let io, io.state == .up {
                    do {
                        try rebindLocked(io)
                    } catch {
                        restoreListenPort(
                            io: io,
                            previousConfiguredPort: previousConfiguredPort,
                            previousBoundPort: previousBoundPort
                        )
                        throw DeviceConfigurationError.portInUse
                    }
                }
            }

            if let targetMark = configuration.firewallMark, targetMark != self.mark {
                if let io {
                    if io.state == .up {
                        do {
                            try io.transport.setFirewallMark(targetMark)
                        } catch {
                            if portChanged {
                                restoreListenPort(
                                    io: io,
                                    previousConfiguredPort: previousConfiguredPort,
                                    previousBoundPort: previousBoundPort
                                )
                            }
                            throw DeviceConfigurationError.portInUse
                        }
                    }
                    self.mark = targetMark
                    clearEndpointSources(io)
                } else {
                    self.mark = targetMark
                }
            }

            // 3. Remove peers no longer present in configuration.
            for existingKey in Array(peers.keys) where !seenKeys.contains(existingKey) {
                removePeer(existingKey)
            }

            // 4. Rotate static identity only when the private key actually changed.
            if !identity.privateKey.matches(configuration.privateKey) {
                identity.privateKey.clear()
                identity = StaticIdentity(privateKey: configuration.privateKey, publicKey: publicKey)
                cookieChecker.clear()
                cookieChecker = CookieChecker(for: publicKey)
                for peer in peers.values {
                    peer.withState { state in
                        clearHandshake(&state.handshake, for: peer)
                        state.lastSentHandshake = nil
                        state.handshake.precompute(privateKey: configuration.privateKey, remote: peer.publicKey)
                        peer.keypairs.withSlots {
                            $0.current?.expireSending()
                            $0.next?.expireSending()
                        }
                    }
                }
            }

            // 5. Diff surviving peers in place and add newly configured peers.
            let brokenRoaming = io?.brokenRoaming ?? false
            for peerConfig in configuration.peers {
                if let existing = peers[peerConfig.publicKey] {
                    let (oldEndpoint, endpointChanged, keepaliveNewlyEnabled) = existing.withState {
                        state -> (IPEndpoint?, Bool, Bool) in
                        let newPSK = peerConfig.presharedKey ?? .zero
                        if state.presharedKey != newPSK {
                            state.presharedKey.clear()
                            state.presharedKey = newPSK
                        }
                        let previousEndpoint = state.endpoint
                        let changed = previousEndpoint != peerConfig.endpoint
                        if changed {
                            state.endpoint = peerConfig.endpoint
                            if brokenRoaming {
                                state.roamingDisabled = peerConfig.endpoint != nil
                            }
                        }
                        let wasDisabled = state.persistentKeepaliveInterval == 0
                        state.persistentKeepaliveInterval = peerConfig.persistentKeepalive
                        return (previousEndpoint, changed, wasDisabled && peerConfig.persistentKeepalive != 0)
                    }

                    if endpointChanged, let io {
                        if let oldEndpoint {
                            io.transport.clearSource(for: oldEndpoint)
                        }
                        if let newEndpoint = peerConfig.endpoint {
                            io.transport.clearSource(for: newEndpoint)
                        }
                    }

                    if peerConfig.persistentKeepalive == 0, let io {
                        timer(.persistentKeepalive, for: existing, after: nil, io: io)
                    }

                    if Set(allowedIPs.prefixes(for: existing)) != Set(peerConfig.allowedIPs) {
                        allowedIPs.removeAll(for: existing)
                        for prefix in peerConfig.allowedIPs {
                            allowedIPs.insert(prefix, for: existing)
                        }
                    }

                    if let io, io.state == .up {
                        startPeer(existing)
                        if keepaliveNewlyEnabled {
                            sendKeepalive(existing)
                        }
                        requestStagedDrain(existing)
                    }
                } else {
                    let peer = WireGuardPeer(publicKey: peerConfig.publicKey)
                    peer.withState { state in
                        state.handshake.precompute(privateKey: identity.privateKey, remote: peerConfig.publicKey)
                        state.presharedKey = peerConfig.presharedKey ?? .zero
                        state.endpoint = peerConfig.endpoint
                        state.persistentKeepaliveInterval = peerConfig.persistentKeepalive
                        state.roamingDisabled = brokenRoaming && peerConfig.endpoint != nil
                    }
                    for prefix in peerConfig.allowedIPs {
                        allowedIPs.insert(prefix, for: peer)
                    }
                    peers[peerConfig.publicKey] = peer
                    if let io, io.state == .up {
                        startPeer(peer)
                        if peerConfig.persistentKeepalive > 0 {
                            sendKeepalive(peer)
                        }
                        requestStagedDrain(peer)
                    }
                }
            }
        }
    }

    private func restoreListenPort(
        io: DeviceIO,
        previousConfiguredPort: UInt16,
        previousBoundPort: UInt16
    ) {
        if previousConfiguredPort == 0, previousBoundPort != 0 {
            configuredPort = previousBoundPort
            if (try? rebindLocked(io)) != nil {
                configuredPort = 0
                return
            }
        }
        configuredPort = previousConfiguredPort
        _ = try? rebindLocked(io)
    }

    private func updateEndpointsLocked(_ endpoints: [WireGuardPublicKey: IPEndpoint?]) {
        lock.withLock {
            guard io?.state != .closed else { return }
            let brokenRoaming = io?.brokenRoaming ?? false
            for (publicKey, endpoint) in endpoints {
                guard let peer = peers[publicKey] else { continue }
                let previousEndpoint: IPEndpoint? = peer.withState { state in
                    let old = state.endpoint
                    state.endpoint = endpoint
                    state.roamingDisabled = brokenRoaming && endpoint != nil
                    return old
                }
                if let io {
                    if let previousEndpoint {
                        io.transport.clearSource(for: previousEndpoint)
                    }
                    if let endpoint {
                        io.transport.clearSource(for: endpoint)
                    }
                }
            }
        }
    }
}
