// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import WireGuardEngine

public enum TunnelProfileCodec {
    public enum ParseError: Error, Equatable, LocalizedError, Sendable {
        case invalidLine(String)
        case noInterface
        case multipleInterfaces
        case interfaceHasNoPrivateKey
        case interfaceHasInvalidPrivateKey(String)
        case interfaceHasInvalidListenPort(String)
        case interfaceHasInvalidAddress(String)
        case interfaceHasInvalidMTU(String)
        case interfaceHasUnrecognizedKey(String)
        case peerHasNoPublicKey
        case peerHasInvalidPublicKey(String)
        case peerHasInvalidPresharedKey(String)
        case peerHasInvalidAllowedIP(String)
        case peerHasInvalidEndpoint(String)
        case peerHasInvalidPersistentKeepalive(String)
        case peerHasUnrecognizedKey(String)
        case duplicatePeerPublicKey
        case multipleEntriesForKey(String)

        public var errorDescription: String? {
            switch self {
            case .invalidLine(let line):
                return "Invalid configuration line: \(line)"
            case .noInterface:
                return "Configuration must contain an [Interface] section."
            case .multipleInterfaces:
                return "Configuration must contain only one [Interface] section."
            case .interfaceHasNoPrivateKey:
                return "Interface is missing a PrivateKey."
            case .interfaceHasInvalidPrivateKey:
                return "Interface PrivateKey must be a nonzero 32-byte key in base64 encoding."
            case .interfaceHasInvalidListenPort(let value):
                return "Interface ListenPort \"\(value)\" is invalid."
            case .interfaceHasInvalidAddress(let value):
                return "Interface Address \"\(value)\" is invalid."
            case .interfaceHasInvalidMTU(let value):
                return InterfaceConfiguration.invalidMTUDescription(value)
            case .interfaceHasUnrecognizedKey(let key):
                return "Unrecognized Interface key \"\(key)\"."
            case .peerHasNoPublicKey:
                return "Peer is missing a PublicKey."
            case .peerHasInvalidPublicKey(let value):
                return "Peer PublicKey \"\(value)\" is invalid."
            case .peerHasInvalidPresharedKey:
                return "Peer PresharedKey is not a valid 32-byte base64 key."
            case .peerHasInvalidAllowedIP(let value):
                return "Peer AllowedIPs entry \"\(value)\" is invalid."
            case .peerHasInvalidEndpoint(let value):
                return "Peer Endpoint \"\(value)\" is invalid."
            case .peerHasInvalidPersistentKeepalive(let value):
                return "Peer PersistentKeepalive \"\(value)\" is invalid."
            case .peerHasUnrecognizedKey(let key):
                return "Unrecognized Peer key \"\(key)\"."
            case .duplicatePeerPublicKey:
                return "Two or more peers have the same PublicKey."
            case .multipleEntriesForKey(let key):
                return "Key \"\(key)\" must appear only once per section."
            }
        }
    }

    private enum ParserState {
        case notInASection
        case inInterfaceSection
        case inPeerSection
    }

    private struct DirectiveAccumulator {
        var explicitMode: SplitDNSConfiguration.Mode?
        var domainNames: [String] = []
        var exclusions: [SplitDNSConfiguration.Exclusion] = []
        var killSwitchEnabled = false
        var allowLocalNetwork = false

        mutating func apply(key: String, value: String) {
            switch key {
            case splitDNSModeKey:
                switch value.lowercased() {
                case "only-domains", "onlydomains", "only", "split":
                    explicitMode = .onlyDomains
                case "all-domains", "alldomains", "all":
                    explicitMode = .allDomains
                default:
                    break
                }
            case splitDNSDomainsKey, "split-dns-domain":
                domainNames.append(contentsOf: parseDomainList(value))
            case splitDNSExcludeKey:
                for name in parseDomainList(value) {
                    exclusions.append(.init(name: name, includesSubdomains: true))
                }
            case splitDNSExcludeExactKey:
                for name in parseDomainList(value) {
                    exclusions.append(.init(name: name, includesSubdomains: false))
                }
            case killSwitchKey:
                if let parsed = parseBool(value) {
                    killSwitchEnabled = parsed
                }
            case killSwitchAllowLANKey:
                if let parsed = parseBool(value) {
                    allowLocalNetwork = parsed
                }
            default:
                break
            }
        }

        func buildSplitDNS() -> SplitDNSConfiguration {
            let domains = domainNames.map { SplitDNSConfiguration.Domain(name: $0) }
            let resolvedMode: SplitDNSConfiguration.Mode
            if let explicitMode {
                resolvedMode = explicitMode
            } else if !domains.isEmpty {
                resolvedMode = .onlyDomains
            } else {
                resolvedMode = .allDomains
            }
            return SplitDNSConfiguration(mode: resolvedMode, domains: domains, exclusions: exclusions)
        }

        func buildOptions() -> TunnelOptions {
            TunnelOptions(
                killSwitch: .init(
                    isEnabled: killSwitchEnabled,
                    allowLocalNetwork: killSwitchEnabled ? allowLocalNetwork : false
                )
            )
        }
    }

    private static let commentPrefix = "# SplitGuard:"
    private static let splitDNSModeKey = "split-dns-mode"
    private static let splitDNSDomainsKey = "split-dns-domains"
    private static let splitDNSExcludeKey = "split-dns-exclude"
    private static let splitDNSExcludeExactKey = "split-dns-exclude-exact"
    private static let killSwitchKey = "kill-switch"
    private static let killSwitchAllowLANKey = "kill-switch-allow-lan"

    private static let repeatableKeys: Set<String> = ["address", "allowedips", "dns"]
    private static let interfaceKeys: Set<String> = ["privatekey", "listenport", "address", "dns", "mtu"]
    private static let peerKeys: Set<String> = ["publickey", "presharedkey", "allowedips", "endpoint", "persistentkeepalive"]

    public static func parse(_ wgQuickConfig: String, name: String = "") throws -> TunnelProfile {
        try parse(wgQuickConfig, name: name, allowUnsupportedMTU: false)
    }

    static func parse(_ wgQuickConfig: String, name: String, allowUnsupportedMTU: Bool) throws -> TunnelProfile {
        var interfaceConfiguration: InterfaceConfiguration?
        var peerConfigurations: [PeerConfiguration] = []
        var directives = DirectiveAccumulator()

        var parserState = ParserState.notInASection
        var attributes: [String: String] = [:]

        func flushSection() throws {
            switch parserState {
            case .notInASection:
                break
            case .inInterfaceSection:
                let parsedInterface = try collateInterface(attributes, allowUnsupportedMTU: allowUnsupportedMTU)
                guard interfaceConfiguration == nil else {
                    throw ParseError.multipleInterfaces
                }
                interfaceConfiguration = parsedInterface
            case .inPeerSection:
                peerConfigurations.append(try collatePeer(attributes))
            }
        }

        let lines = wgQuickConfig.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for rawLine in lines {
            let trimmedFull = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedFull.hasPrefix("#") {
                if let directive = parseSplitGuardDirective(from: trimmedFull) {
                    directives.apply(key: directive.key, value: directive.value)
                }
                continue
            }

            let uncommented: Substring
            if let commentIndex = rawLine.firstIndex(of: "#") {
                uncommented = rawLine[..<commentIndex]
            } else {
                uncommented = rawLine
            }

            let trimmed = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let lowercased = trimmed.lowercased()
            if lowercased == "[interface]" {
                try flushSection()
                parserState = .inInterfaceSection
                attributes.removeAll(keepingCapacity: true)
                continue
            }
            if lowercased == "[peer]" {
                try flushSection()
                parserState = .inPeerSection
                attributes.removeAll(keepingCapacity: true)
                continue
            }

            guard parserState != .notInASection, let equalsIndex = trimmed.firstIndex(of: "=") else {
                throw ParseError.invalidLine(String(rawLine))
            }

            let keyWithCase = trimmed[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let key = keyWithCase.lowercased()
            let value = trimmed[trimmed.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)

            switch parserState {
            case .inInterfaceSection:
                guard interfaceKeys.contains(key) else {
                    throw ParseError.interfaceHasUnrecognizedKey(keyWithCase)
                }
            case .inPeerSection:
                guard peerKeys.contains(key) else {
                    throw ParseError.peerHasUnrecognizedKey(keyWithCase)
                }
            case .notInASection:
                throw ParseError.invalidLine(String(rawLine))
            }

            if let existing = attributes[key] {
                if repeatableKeys.contains(key) {
                    attributes[key] = existing + "," + value
                } else {
                    throw ParseError.multipleEntriesForKey(keyWithCase)
                }
            } else {
                attributes[key] = value
            }
        }

        try flushSection()

        guard let interfaceConfiguration else {
            throw ParseError.noInterface
        }

        do {
            return try TunnelProfile(
                name: name,
                interface: interfaceConfiguration,
                peers: peerConfigurations,
                splitDNS: directives.buildSplitDNS(),
                options: directives.buildOptions()
            )
        } catch TunnelProfileError.duplicatePeerPublicKey {
            throw ParseError.duplicatePeerPublicKey
        }
    }

    public static func serialize(_ profile: TunnelProfile) -> String {
        var output = ""

        let headerLines = directiveHeaderLines(for: profile)
        if !headerLines.isEmpty {
            output.append(headerLines.joined(separator: "\n"))
            output.append("\n")
        }

        output.append("[Interface]\n")
        output.append("PrivateKey = \(profile.interface.privateKey.base64)\n")
        if let listenPort = profile.interface.listenPort {
            output.append("ListenPort = \(listenPort)\n")
        }
        if !profile.interface.addresses.isEmpty {
            let addresses = profile.interface.addresses.map(\.description).joined(separator: ", ")
            output.append("Address = \(addresses)\n")
        }
        if !profile.interface.dnsServers.isEmpty || !profile.interface.dnsSearch.isEmpty {
            var dnsEntries = profile.interface.dnsServers.map(\.description)
            dnsEntries.append(contentsOf: profile.interface.dnsSearch)
            output.append("DNS = \(dnsEntries.joined(separator: ", "))\n")
        }
        if let mtu = profile.interface.mtu {
            output.append("MTU = \(mtu)\n")
        }

        for peer in profile.peers {
            output.append("\n[Peer]\n")
            output.append("PublicKey = \(peer.publicKey.base64)\n")
            if let presharedKey = peer.presharedKey {
                output.append("PresharedKey = \(presharedKey.base64)\n")
            }
            if !peer.allowedIPs.isEmpty {
                let allowedIPs = peer.allowedIPs.map(\.description).joined(separator: ", ")
                output.append("AllowedIPs = \(allowedIPs)\n")
            }
            if let endpoint = peer.endpoint {
                output.append("Endpoint = \(endpoint.description)\n")
            }
            if let keepalive = peer.persistentKeepalive {
                output.append("PersistentKeepalive = \(keepalive)\n")
            }
        }

        return output
    }

    // MARK: - Section Collation

    private static func collateInterface(
        _ attributes: [String: String],
        allowUnsupportedMTU: Bool
    ) throws -> InterfaceConfiguration {
        guard let privateKeyString = attributes["privatekey"] else {
            throw ParseError.interfaceHasNoPrivateKey
        }
        guard let privateKey = WireGuardPrivateKey(base64: privateKeyString) else {
            throw ParseError.interfaceHasInvalidPrivateKey(privateKeyString)
        }

        var config = InterfaceConfiguration(privateKey: privateKey)

        if let listenPortString = attributes["listenport"] {
            guard let listenPort = parseUnsignedDecimal(listenPortString[...], as: UInt16.self) else {
                throw ParseError.interfaceHasInvalidListenPort(listenPortString)
            }
            config.listenPort = listenPort
        }

        if let addressesString = attributes["address"] {
            var addresses: [InterfaceAddress] = []
            for item in splitCommaSeparated(addressesString) {
                guard let address = InterfaceAddress(item) else {
                    throw ParseError.interfaceHasInvalidAddress(item)
                }
                addresses.append(address)
            }
            config.addresses = addresses
        }

        if let dnsString = attributes["dns"] {
            var dnsServers: [IPAddress] = []
            var dnsSearch: [String] = []
            for item in splitCommaSeparated(dnsString) {
                if let ipAddress = IPAddress(item), ipAddress.zoneID == nil {
                    dnsServers.append(ipAddress)
                } else {
                    dnsSearch.append(item)
                }
            }
            config.dnsServers = dnsServers
            config.dnsSearch = dnsSearch
        }

        if let mtuString = attributes["mtu"] {
            guard let mtu = parseUnsignedDecimal(mtuString[...], as: UInt16.self),
                  allowUnsupportedMTU || InterfaceConfiguration.isSupportedMTU(mtu) else {
                throw ParseError.interfaceHasInvalidMTU(mtuString)
            }
            config.mtu = mtu
        }

        return config
    }

    private static func collatePeer(_ attributes: [String: String]) throws -> PeerConfiguration {
        guard let publicKeyString = attributes["publickey"] else {
            throw ParseError.peerHasNoPublicKey
        }
        guard let publicKey = WireGuardPublicKey(base64: publicKeyString) else {
            throw ParseError.peerHasInvalidPublicKey(publicKeyString)
        }

        var peer = PeerConfiguration(publicKey: publicKey)

        if let presharedKeyString = attributes["presharedkey"] {
            guard let presharedKey = WireGuardPresharedKey(base64: presharedKeyString) else {
                throw ParseError.peerHasInvalidPresharedKey(presharedKeyString)
            }
            peer.presharedKey = presharedKey
        }

        if let allowedIPsString = attributes["allowedips"] {
            var allowedIPs: [IPPrefix] = []
            for item in splitCommaSeparated(allowedIPsString) {
                guard let parsed = InterfaceAddress(item) else {
                    throw ParseError.peerHasInvalidAllowedIP(item)
                }
                allowedIPs.append(parsed.network)
            }
            peer.allowedIPs = allowedIPs
        }

        if let endpointString = attributes["endpoint"] {
            guard let endpoint = Endpoint(endpointString) else {
                throw ParseError.peerHasInvalidEndpoint(endpointString)
            }
            peer.endpoint = endpoint
        }

        if let keepaliveString = attributes["persistentkeepalive"] {
            guard let keepalive = parseUnsignedDecimal(keepaliveString[...], as: UInt16.self) else {
                throw ParseError.peerHasInvalidPersistentKeepalive(keepaliveString)
            }
            peer.persistentKeepalive = keepalive
        }

        return peer
    }

    // MARK: - SplitGuard Directives

    private static func parseSplitGuardDirective(from trimmedCommentLine: String) -> (key: String, value: String)? {
        let afterHash = trimmedCommentLine.dropFirst().trimmingCharacters(in: .whitespaces)
        guard afterHash.lowercased().hasPrefix("splitguard:") else { return nil }
        let directive = afterHash.dropFirst("splitguard:".count).trimmingCharacters(in: .whitespaces)
        guard let equalsIndex = directive.firstIndex(of: "=") else { return nil }

        let key = directive[..<equalsIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let value = directive[directive.index(after: equalsIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return (key: key, value: value)
    }

    private static func directiveHeaderLines(for profile: TunnelProfile) -> [String] {
        var lines: [String] = []

        if !profile.splitDNS.isDefault {
            let modeValue = profile.splitDNS.mode == .onlyDomains ? "only-domains" : "all-domains"
            lines.append("\(commentPrefix) \(splitDNSModeKey) = \(modeValue)")

            let names = profile.splitDNS.normalizedDomainNames
            if !names.isEmpty {
                lines.append("\(commentPrefix) \(splitDNSDomainsKey) = \(names.joined(separator: ", "))")
            }

            let wildcardExclusions = profile.splitDNS.exclusions
                .filter(\.includesSubdomains)
                .map { SplitDNSConfiguration.normalizeDomain($0.name) }
                .filter { !$0.isEmpty }
            if !wildcardExclusions.isEmpty {
                lines.append("\(commentPrefix) \(splitDNSExcludeKey) = \(wildcardExclusions.joined(separator: ", "))")
            }

            let exactExclusions = profile.splitDNS.exclusions
                .filter { !$0.includesSubdomains }
                .map { SplitDNSConfiguration.normalizeDomain($0.name) }
                .filter { !$0.isEmpty }
            if !exactExclusions.isEmpty {
                lines.append("\(commentPrefix) \(splitDNSExcludeExactKey) = \(exactExclusions.joined(separator: ", "))")
            }
        }

        let sanitizedOptions = profile.options.sanitized(for: profile)
        if sanitizedOptions.killSwitch.isEnabled {
            lines.append("\(commentPrefix) \(killSwitchKey) = on")
            if sanitizedOptions.killSwitch.allowLocalNetwork {
                lines.append("\(commentPrefix) \(killSwitchAllowLANKey) = on")
            }
        }

        return lines
    }

    private static func splitCommaSeparated(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func parseDomainList(_ value: String) -> [String] {
        value
            .split { $0 == "," || $0.isWhitespace }
            .map { SplitDNSConfiguration.normalizeDomain(String($0)) }
            .filter { SplitDNSConfiguration.isValidDomainName($0) }
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "on", "true", "1", "yes":
            return true
        case "off", "false", "0", "no":
            return false
        default:
            return nil
        }
    }
}
