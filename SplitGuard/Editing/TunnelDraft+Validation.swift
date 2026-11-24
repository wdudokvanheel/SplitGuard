// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore
import WireGuardEngine

extension TunnelDraft {
    func validate(
        splitDNS: SplitDNSConfiguration = .allDomains,
        options: TunnelOptions = .default
    ) -> Result<TunnelProfile, TunnelDraftValidationError> {
        let interfaceResult = validateInterface()
        let peersResult = validatePeers()

        if let firstInterfaceError = interfaceResult.messages.first {
            return .failure(TunnelDraftValidationError(
                title: tr("alertInvalidInterfaceTitle"),
                message: firstInterfaceError,
                interfaceFields: interfaceResult.errorFields,
                peerFieldsByID: peersResult.errorFieldsByID
            ))
        }

        if let firstPeerError = peersResult.messages.first {
            return .failure(TunnelDraftValidationError(
                title: tr("alertInvalidPeerTitle"),
                message: firstPeerError,
                interfaceFields: interfaceResult.errorFields,
                peerFieldsByID: peersResult.errorFieldsByID
            ))
        }

        return buildProfile(
            interfaceResult: interfaceResult,
            peersResult: peersResult,
            splitDNS: splitDNS,
            options: options
        )
    }
}

private extension TunnelDraft {
    struct InterfaceValidationOutput {
        var name: String?
        var configuration: InterfaceConfiguration?
        var errorFields: Set<InterfaceField> = []
        var messages: [String] = []
    }

    struct PeerValidationOutput {
        var configuration: PeerConfiguration?
        var errorFields: Set<PeerField> = []
        var messages: [String] = []
    }

    struct PeersValidationOutput {
        var configurations: [PeerConfiguration] = []
        var errorFieldsByID: [UUID: Set<PeerField>] = [:]
        var messages: [String] = []
    }

    func buildProfile(
        interfaceResult: InterfaceValidationOutput,
        peersResult: PeersValidationOutput,
        splitDNS: SplitDNSConfiguration,
        options: TunnelOptions
    ) -> Result<TunnelProfile, TunnelDraftValidationError> {
        guard let validatedName = interfaceResult.name,
              let validatedInterface = interfaceResult.configuration else {
            return .failure(TunnelDraftValidationError(
                title: tr("alertInvalidInterfaceTitle"),
                message: tr("alertInvalidInterfaceMessageNameRequired"),
                interfaceFields: interfaceResult.errorFields,
                peerFieldsByID: peersResult.errorFieldsByID
            ))
        }

        do {
            let profile = try TunnelProfile(
                name: validatedName,
                interface: validatedInterface,
                peers: peersResult.configurations,
                splitDNS: splitDNS,
                options: options
            )
            return .success(profile)
        } catch TunnelProfileError.duplicatePeerPublicKey {
            return .failure(TunnelDraftValidationError(
                title: tr("alertInvalidPeerTitle"),
                message: tr("alertInvalidPeerMessagePublicKeyDuplicated"),
                interfaceFields: [],
                peerFieldsByID: peersResult.errorFieldsByID
            ))
        } catch {
            return .failure(TunnelDraftValidationError(
                title: tr("alertInvalidPeerTitle"),
                message: error.localizedDescription,
                interfaceFields: [],
                peerFieldsByID: peersResult.errorFieldsByID
            ))
        }
    }

    func validateInterface() -> InterfaceValidationOutput {
        var output = InterfaceValidationOutput()
        let trimmedName = parseInterfaceName(into: &output)
        let privateKey = parseInterfacePrivateKey(into: &output)
        let addresses = parseInterfaceAddresses(into: &output)
        let listenPort = parseOptionalPort(interface.listenPort, into: &output)
        let mtu = parseOptionalMTU(interface.mtu, into: &output)
        let (dnsServers, dnsSearch) = parseInterfaceDNS()

        if output.messages.isEmpty, let trimmedName, let privateKey {
            output.name = trimmedName
            output.configuration = InterfaceConfiguration(
                privateKey: privateKey,
                addresses: addresses,
                listenPort: listenPort,
                mtu: mtu,
                dnsServers: dnsServers,
                dnsSearch: dnsSearch
            )
        }
        return output
    }

    func parseInterfaceName(into output: inout InterfaceValidationOutput) -> String? {
        let trimmed = interface.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            output.errorFields.insert(.name)
            output.messages.append(tr("alertInvalidInterfaceMessageNameRequired"))
            return nil
        }
        return trimmed
    }

    func parseInterfacePrivateKey(into output: inout InterfaceValidationOutput) -> WireGuardPrivateKey? {
        let trimmed = interface.privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            output.errorFields.insert(.privateKey)
            output.messages.append(tr("alertInvalidInterfaceMessagePrivateKeyRequired"))
            return nil
        }
        guard let parsedKey = WireGuardPrivateKey(base64: trimmed) else {
            output.errorFields.insert(.privateKey)
            output.messages.append(tr("alertInvalidInterfaceMessagePrivateKeyInvalid"))
            return nil
        }
        return parsedKey
    }

    func parseInterfaceAddresses(into output: inout InterfaceValidationOutput) -> [InterfaceAddress] {
        var addresses: [InterfaceAddress] = []
        for item in AllowedIPHelpers.splitCommaSeparated(interface.addresses) {
            if let address = InterfaceAddress(item) {
                addresses.append(address)
            } else {
                output.errorFields.insert(.addresses)
                output.messages.append(tr("alertInvalidInterfaceMessageAddressInvalid"))
            }
        }
        return addresses
    }

    func parseOptionalPort(_ raw: String, into output: inout InterfaceValidationOutput) -> UInt16? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Self.parseUInt16(trimmed) else {
            output.errorFields.insert(.listenPort)
            output.messages.append(tr("alertInvalidInterfaceMessageListenPortInvalid"))
            return nil
        }
        return value
    }

    func parseOptionalMTU(_ raw: String, into output: inout InterfaceValidationOutput) -> UInt16? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Self.parseUInt16(trimmed), value >= 576 else {
            output.errorFields.insert(.mtu)
            output.messages.append(tr("alertInvalidInterfaceMessageMTUInvalid"))
            return nil
        }
        return value
    }

    func parseInterfaceDNS() -> ([IPAddress], [String]) {
        var dnsServers: [IPAddress] = []
        var dnsSearch: [String] = []
        for item in AllowedIPHelpers.splitCommaSeparated(interface.dns) {
            if let ipAddress = IPAddress(item), ipAddress.zoneID == nil {
                dnsServers.append(ipAddress)
            } else {
                dnsSearch.append(item)
            }
        }
        return (dnsServers, dnsSearch)
    }

    func validatePeers() -> PeersValidationOutput {
        var output = PeersValidationOutput()
        var seenKeyToPeerID: [WireGuardPublicKey: UUID] = [:]

        for peer in peers {
            let result = validatePeer(peer)
            if !result.errorFields.isEmpty {
                output.errorFieldsByID[peer.id] = result.errorFields
            }
            output.messages.append(contentsOf: result.messages)

            if let config = result.configuration {
                if let existingID = seenKeyToPeerID[config.publicKey] {
                    output.errorFieldsByID[existingID, default: []].insert(.publicKey)
                    output.errorFieldsByID[peer.id, default: []].insert(.publicKey)
                    output.messages.append(tr("alertInvalidPeerMessagePublicKeyDuplicated"))
                } else {
                    seenKeyToPeerID[config.publicKey] = peer.id
                }
                output.configurations.append(config)
            }
        }
        return output
    }

    func validatePeer(_ peer: PeerDraft) -> PeerValidationOutput {
        var output = PeerValidationOutput()
        let publicKey = parsePeerPublicKey(peer.publicKey, into: &output)
        let presharedKey = parsePeerPresharedKey(peer.presharedKey, into: &output)
        let allowedIPs = parsePeerAllowedIPs(peer.allowedIPs, into: &output)
        let endpoint = parsePeerEndpoint(peer.endpoint, into: &output)
        let keepalive = parsePeerKeepalive(peer.persistentKeepalive, into: &output)

        if output.messages.isEmpty, let publicKey {
            output.configuration = PeerConfiguration(
                publicKey: publicKey,
                presharedKey: presharedKey,
                allowedIPs: allowedIPs,
                endpoint: endpoint,
                persistentKeepalive: keepalive
            )
        }
        return output
    }

    func parsePeerPublicKey(_ raw: String, into output: inout PeerValidationOutput) -> WireGuardPublicKey? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            output.errorFields.insert(.publicKey)
            output.messages.append(tr("alertInvalidPeerMessagePublicKeyRequired"))
            return nil
        }
        guard let parsed = WireGuardPublicKey(base64: trimmed) else {
            output.errorFields.insert(.publicKey)
            output.messages.append(tr("alertInvalidPeerMessagePublicKeyInvalid"))
            return nil
        }
        return parsed
    }

    func parsePeerPresharedKey(_ raw: String, into output: inout PeerValidationOutput) -> WireGuardPresharedKey? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let parsed = WireGuardPresharedKey(base64: trimmed) else {
            output.errorFields.insert(.presharedKey)
            output.messages.append(tr("alertInvalidPeerMessagePreSharedKeyInvalid"))
            return nil
        }
        return parsed
    }

    func parsePeerAllowedIPs(_ raw: String, into output: inout PeerValidationOutput) -> [IPPrefix] {
        var allowedIPs: [IPPrefix] = []
        for item in AllowedIPHelpers.splitCommaSeparated(raw) {
            if let address = InterfaceAddress(item) {
                allowedIPs.append(address.network)
            } else {
                output.errorFields.insert(.allowedIPs)
                output.messages.append(tr("alertInvalidPeerMessageAllowedIPsInvalid"))
            }
        }
        return allowedIPs
    }

    func parsePeerEndpoint(_ raw: String, into output: inout PeerValidationOutput) -> Endpoint? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let parsed = Endpoint(trimmed) else {
            output.errorFields.insert(.endpoint)
            output.messages.append(tr("alertInvalidPeerMessageEndpointInvalid"))
            return nil
        }
        return parsed
    }

    func parsePeerKeepalive(_ raw: String, into output: inout PeerValidationOutput) -> UInt16? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let parsed = Self.parseUInt16(trimmed) else {
            output.errorFields.insert(.persistentKeepalive)
            output.messages.append(tr("alertInvalidPeerMessagePersistentKeepaliveInvalid"))
            return nil
        }
        return parsed
    }

    static func parseUInt16(_ text: String) -> UInt16? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }
        return UInt16(text)
    }
}
