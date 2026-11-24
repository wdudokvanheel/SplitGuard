// SPDX-License-Identifier: MIT

import Foundation
import NetworkExtension
import enum SplitGuardCore.Log

struct OnDemandPolicy: Equatable, Hashable, Sendable {
    enum SSIDFilter: Equatable, Hashable, Sendable {
        case any
        case only([String])
        case except([String])
    }

    enum SSIDOptionKind: Equatable, Hashable, CaseIterable, Sendable {
        case any
        case only
        case except

        var title: String {
            switch self {
            case .any:
                return "Any SSID"
            case .only:
                return "Only these SSIDs"
            case .except:
                return "Except these SSIDs"
            }
        }
    }

    var cellular: Bool
    var wifi: Bool
    var ssidFilter: SSIDFilter

    static let off = OnDemandPolicy(cellular: false, wifi: false, ssidFilter: .any)

    var hasRules: Bool {
        cellular || wifi
    }

    init(cellular: Bool = false, wifi: Bool = false, ssidFilter: SSIDFilter = .any) {
        self.cellular = cellular
        self.wifi = wifi
        self.ssidFilter = ssidFilter
    }

    mutating func normalize() {
        guard wifi else {
            ssidFilter = .any
            return
        }
        switch ssidFilter {
        case .any:
            break
        case .only(let ssids):
            let cleaned = Self.cleanSSIDs(ssids)
            ssidFilter = cleaned.isEmpty ? .any : .only(cleaned)
        case .except(let ssids):
            let cleaned = Self.cleanSSIDs(ssids)
            ssidFilter = cleaned.isEmpty ? .any : .except(cleaned)
        }
    }

    func normalized() -> OnDemandPolicy {
        var copy = self
        copy.normalize()
        return copy
    }

    init(from rules: [NEOnDemandRule]?) {
        guard let rules, !rules.isEmpty else {
            self = .off
            return
        }

        switch rules.count {
        case 1:
            self = Self.parseSingleRule(rules[0])
        case 2:
            self = Self.parsePairRules(rules)
        case 3:
            self = Self.parseSSIDAndCellularRules(rules)
        default:
            Log.error("Unexpected number of onDemandRules: \(rules.count)")
            self = .off
        }
    }

    private static func parseSingleRule(_ rule: NEOnDemandRule) -> OnDemandPolicy {
        guard rule.action == .connect else {
            return .off
        }
        switch rule.interfaceTypeMatch {
        case .wiFi:
            return OnDemandPolicy(cellular: false, wifi: true, ssidFilter: .any)
        case .cellular:
            return OnDemandPolicy(cellular: true, wifi: false, ssidFilter: .any)
        default:
            return OnDemandPolicy(cellular: true, wifi: true, ssidFilter: .any)
        }
    }

    private static func parsePairRules(_ rules: [NEOnDemandRule]) -> OnDemandPolicy {
        guard let connectRule = rules.first(where: { $0.action == .connect }),
              let disconnectRule = rules.first(where: { $0.action == .disconnect }) else {
            Log.error("Unexpected onDemandRules: 2 rules found without connect/disconnect pair.")
            return .off
        }
        if connectRule.interfaceTypeMatch == .wiFi && disconnectRule.interfaceTypeMatch == .cellular {
            return OnDemandPolicy(cellular: false, wifi: true, ssidFilter: .any)
        }
        if connectRule.interfaceTypeMatch == .cellular && disconnectRule.interfaceTypeMatch == .wiFi {
            return OnDemandPolicy(cellular: true, wifi: false, ssidFilter: .any)
        }
        Log.error("Unexpected onDemandRules: 2 rules found with inconsistent interface types.")
        return .off
    }

    private static func parseSSIDAndCellularRules(_ rules: [NEOnDemandRule]) -> OnDemandPolicy {
        guard let ssidRule = rules.first(where: { $0.interfaceTypeMatch == .wiFi && $0.ssidMatch != nil }),
              let ssids = ssidRule.ssidMatch,
              let cellularRule = rules.first(where: { $0.interfaceTypeMatch == .cellular }) else {
            return .off
        }
        switch (ssidRule.action, cellularRule.action) {
        case (.connect, .connect):
            return OnDemandPolicy(cellular: true, wifi: true, ssidFilter: .only(ssids)).normalized()
        case (.connect, .disconnect):
            return OnDemandPolicy(cellular: false, wifi: true, ssidFilter: .only(ssids)).normalized()
        case (.disconnect, .connect):
            return OnDemandPolicy(cellular: true, wifi: true, ssidFilter: .except(ssids)).normalized()
        case (.disconnect, .disconnect):
            return OnDemandPolicy(cellular: false, wifi: true, ssidFilter: .except(ssids)).normalized()
        default:
            Log.error("Unexpected onDemandRules: 3 rules found with unsupported actions.")
            return .off
        }
    }

    func makeRules() -> [NEOnDemandRule] {
        let policy = normalized()
        switch (policy.wifi, policy.cellular) {
        case (false, false):
            return []
        case (false, true):
            return [
                Self.connectRule(interfaceType: .cellular),
                Self.disconnectRule(interfaceType: .wiFi)
            ]
        case (true, false):
            return Self.wifiRules(for: policy.ssidFilter) + [
                Self.disconnectRule(interfaceType: .cellular)
            ]
        case (true, true):
            if case .any = policy.ssidFilter {
                return [Self.connectRule(interfaceType: .any)]
            }
            return Self.wifiRules(for: policy.ssidFilter) + [
                Self.connectRule(interfaceType: .cellular)
            ]
        }
    }

    func apply(to manager: NEVPNManager) {
        let rules = makeRules()
        manager.onDemandRules = rules.isEmpty ? nil : rules
        manager.isOnDemandEnabled = !rules.isEmpty && manager.isOnDemandEnabled
    }

    private static func cleanSSIDs(_ ssids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in ssids {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func wifiRules(for filter: SSIDFilter) -> [NEOnDemandRule] {
        switch filter {
        case .any:
            return [connectRule(interfaceType: .wiFi)]
        case .only(let ssids):
            return [
                connectRule(interfaceType: .wiFi, ssids: ssids),
                disconnectRule(interfaceType: .wiFi)
            ]
        case .except(let ssids):
            return [
                disconnectRule(interfaceType: .wiFi, ssids: ssids),
                connectRule(interfaceType: .wiFi)
            ]
        }
    }

    private static func connectRule(
        interfaceType: NEOnDemandRuleInterfaceType,
        ssids: [String]? = nil
    ) -> NEOnDemandRuleConnect {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = interfaceType
        rule.ssidMatch = ssids
        return rule
    }

    private static func disconnectRule(
        interfaceType: NEOnDemandRuleInterfaceType,
        ssids: [String]? = nil
    ) -> NEOnDemandRuleDisconnect {
        let rule = NEOnDemandRuleDisconnect()
        rule.interfaceTypeMatch = interfaceType
        rule.ssidMatch = ssids
        return rule
    }
}

extension OnDemandPolicy {
    var interfaceDescription: String {
        switch (wifi, cellular) {
        case (false, false):
            return "Off"
        case (true, false):
            return "Wi-Fi only"
        case (false, true):
            return "Cellular only"
        case (true, true):
            return "Wi-Fi or cellular"
        }
    }

    var ssidDescription: String {
        guard wifi else { return "" }
        switch ssidFilter {
        case .any:
            return "Any SSID"
        case .only(let ssids):
            return ssids.count == 1 ? "Only 1 SSID" : "Only \(ssids.count) SSIDs"
        case .except(let ssids):
            return ssids.count == 1 ? "Except 1 SSID" : "Except \(ssids.count) SSIDs"
        }
    }

    var selectedSSIDs: [String] {
        switch ssidFilter {
        case .any:
            return []
        case .only(let ssids), .except(let ssids):
            return ssids
        }
    }

    var ssidOptionKind: SSIDOptionKind {
        switch ssidFilter {
        case .any:
            return .any
        case .only:
            return .only
        case .except:
            return .except
        }
    }
}
