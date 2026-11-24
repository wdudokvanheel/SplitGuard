// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore
import WireGuardEngine

enum InterfaceField: Hashable, CaseIterable, Sendable {
    case name
    case privateKey
    case publicKey
    case addresses
    case listenPort
    case mtu
    case dns

    var localizedTitle: String {
        switch self {
        case .name:
            return String(localized: "tunnel.interface.name", defaultValue: "Name")
        case .privateKey:
            return String(localized: "tunnel.interface.privateKey", defaultValue: "Private key")
        case .publicKey:
            return String(localized: "tunnel.interface.publicKey", defaultValue: "Public key")
        case .addresses:
            return String(localized: "tunnel.interface.addresses", defaultValue: "Addresses")
        case .listenPort:
            return String(localized: "tunnel.interface.listenPort", defaultValue: "Listen port")
        case .mtu:
            return String(localized: "tunnel.interface.mtu", defaultValue: "MTU")
        case .dns:
            return String(localized: "tunnel.interface.dns", defaultValue: "DNS servers")
        }
    }
}

enum PeerField: Hashable, CaseIterable, Sendable {
    case publicKey
    case presharedKey
    case endpoint
    case allowedIPs
    case persistentKeepalive

    var localizedTitle: String {
        switch self {
        case .publicKey:
            return String(localized: "tunnel.peer.publicKey", defaultValue: "Public key")
        case .presharedKey:
            return String(localized: "tunnel.peer.presharedKey", defaultValue: "Preshared key")
        case .endpoint:
            return String(localized: "tunnel.peer.endpoint", defaultValue: "Endpoint")
        case .allowedIPs:
            return String(localized: "tunnel.peer.allowedIPs", defaultValue: "Allowed IPs")
        case .persistentKeepalive:
            return String(localized: "tunnel.peer.persistentKeepalive", defaultValue: "Persistent keepalive")
        }
    }
}

struct InterfaceDraft: Equatable, Sendable {
    var name: String
    var privateKey: String
    var addresses: String
    var listenPort: String
    var mtu: String
    var dns: String

    init(
        name: String = "",
        privateKey: String = "",
        addresses: String = "",
        listenPort: String = "",
        mtu: String = "",
        dns: String = ""
    ) {
        self.name = name
        self.privateKey = privateKey
        self.addresses = addresses
        self.listenPort = listenPort
        self.mtu = mtu
        self.dns = dns
    }

    init(name: String, configuration: InterfaceConfiguration) {
        self.name = name
        self.privateKey = configuration.privateKey.base64
        self.addresses = configuration.addresses.map(\.description).joined(separator: ", ")
        self.listenPort = configuration.listenPort.map(String.init) ?? ""
        self.mtu = configuration.mtu.map(String.init) ?? ""
        var dnsEntries = configuration.dnsServers.map(\.description)
        dnsEntries.append(contentsOf: configuration.dnsSearch)
        self.dns = dnsEntries.joined(separator: ", ")
    }

    var derivedPublicKey: String {
        let trimmed = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 44,
              let key = WireGuardPrivateKey(base64: trimmed),
              let derived = try? key.publicKey() else {
            return ""
        }
        return derived.base64
    }
}

struct PeerDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    var publicKey: String
    var presharedKey: String
    var endpoint: String
    var allowedIPs: String
    var persistentKeepalive: String

    init(
        id: UUID = UUID(),
        publicKey: String = "",
        presharedKey: String = "",
        endpoint: String = "",
        allowedIPs: String = "",
        persistentKeepalive: String = ""
    ) {
        self.id = id
        self.publicKey = publicKey
        self.presharedKey = presharedKey
        self.endpoint = endpoint
        self.allowedIPs = allowedIPs
        self.persistentKeepalive = persistentKeepalive
    }

    init(id: UUID = UUID(), configuration: PeerConfiguration) {
        self.id = id
        self.publicKey = configuration.publicKey.base64
        self.presharedKey = configuration.presharedKey?.base64 ?? ""
        self.endpoint = configuration.endpoint?.description ?? ""
        self.allowedIPs = configuration.allowedIPs.map(\.description).joined(separator: ", ")
        self.persistentKeepalive = configuration.persistentKeepalive.map(String.init) ?? ""
    }

    subscript(field: PeerField) -> String {
        get {
            switch field {
            case .publicKey:
                return publicKey
            case .presharedKey:
                return presharedKey
            case .endpoint:
                return endpoint
            case .allowedIPs:
                return allowedIPs
            case .persistentKeepalive:
                return persistentKeepalive
            }
        }
        set {
            switch field {
            case .publicKey:
                publicKey = newValue
            case .presharedKey:
                presharedKey = newValue
            case .endpoint:
                endpoint = newValue
            case .allowedIPs:
                allowedIPs = newValue
            case .persistentKeepalive:
                persistentKeepalive = newValue
            }
        }
    }
}

struct TunnelDraftValidationError: Error, Equatable, Sendable {
    let title: String
    let message: String
    let interfaceFields: Set<InterfaceField>
    let peerFieldsByID: [UUID: Set<PeerField>]
}

struct TunnelDraft: Equatable, Sendable {
    var interface: InterfaceDraft
    var peers: [PeerDraft]

    init(interface: InterfaceDraft = InterfaceDraft(), peers: [PeerDraft] = []) {
        self.interface = interface
        self.peers = peers
    }

    init(profile: TunnelProfile) {
        self.interface = InterfaceDraft(name: profile.name, configuration: profile.interface)
        self.peers = profile.peers.map { PeerDraft(configuration: $0) }
    }
}
