// SPDX-License-Identifier: MIT

import Foundation
import NetworkExtension
import Observation
import SplitGuardCore
import WireGuardEngine

@MainActor
@Observable
final class TunnelEditorViewModel {
    let existingTunnel: Tunnel?

    var draft: TunnelDraft
    private(set) var interfaceErrorFields: Set<InterfaceField> = []
    private(set) var peerErrorFieldsByID: [UUID: Set<PeerField>] = [:]

    var isCellularOnDemandEnabled = false
    var isWiFiOnDemandEnabled = false
    var ssidOption: OnDemandPolicy.SSIDOptionKind = .any
    var selectedSSIDs: [String] = []

    var splitDNSMode: SplitDNSConfiguration.Mode = .allDomains
    var splitDNSDomains: [SplitDNSConfiguration.Domain] = []
    var splitDNSExclusions: [SplitDNSConfiguration.Exclusion] = []
    var newSplitDNSDomain = ""
    var splitDNSInputError: String?
    var newSplitDNSExclusion = ""
    var splitDNSExclusionInputError: String?

    var isKillSwitchEnabled = false
    var allowLocalNetworkWithKillSwitch = false

    var validationAlert: AlertItem?
    var isSaving = false

    private var previousDNSValue = ""

    init(tunnel: Tunnel? = nil) {
        self.existingTunnel = tunnel
        self.draft = tunnel.map { TunnelDraft(profile: $0.profile) } ?? TunnelDraft()

        loadInitialState()
    }

    var isEditing: Bool {
        existingTunnel != nil
    }

    var navigationTitle: String {
        isEditing ? tr("editTunnelViewTitle") : tr("newTunnelViewTitle")
    }

    var name: String {
        draft.interface.name
    }

    var privateKey: String {
        draft.interface.privateKey
    }

    var publicKey: String {
        draft.interface.derivedPublicKey
    }

    var addresses: String {
        draft.interface.addresses
    }

    var listenPort: String {
        draft.interface.listenPort
    }

    var mtu: String {
        draft.interface.mtu
    }

    var dns: String {
        draft.interface.dns
    }

    var peers: [PeerDraft] {
        draft.peers
    }

    var shouldStronglyRecommendDNS: Bool {
        draft.peers.contains { AllowedIPHelpers.shouldStronglyRecommendDNS(allowedIPsText: $0.allowedIPs) }
    }

    func updateName(_ value: String) {
        draft.interface.name = value
        interfaceErrorFields.remove(.name)
    }

    func updatePrivateKey(_ value: String) {
        draft.interface.privateKey = value
        interfaceErrorFields.remove(.privateKey)
    }

    func generateKeyPair() {
        updatePrivateKey(WireGuardPrivateKey.generate().base64)
    }

    func updateAddresses(_ value: String) {
        draft.interface.addresses = value
        interfaceErrorFields.remove(.addresses)
    }

    func updateListenPort(_ value: String) {
        draft.interface.listenPort = value
        interfaceErrorFields.remove(.listenPort)
    }

    func updateMTU(_ value: String) {
        draft.interface.mtu = value
        interfaceErrorFields.remove(.mtu)
    }

    func updateDNS(_ value: String) {
        let oldValue = previousDNSValue
        draft.interface.dns = value
        interfaceErrorFields.remove(.dns)

        if draft.peers.count == 1 {
            let currentAllowed = draft.peers[0].allowedIPs
            let isExcluding = AllowedIPHelpers.isExcludingPrivateIPs(allowedIPs: currentAllowed)
            if let updated = AllowedIPHelpers.updatingDNSServersInAllowedIPs(
                allowedIPsText: currentAllowed,
                oldDNSText: oldValue,
                newDNSText: value,
                isExcludingPrivateIPs: isExcluding
            ) {
                draft.peers[0].allowedIPs = updated
            }
        }
        previousDNSValue = value
    }

    func peerValue(for peerID: UUID, field: PeerField) -> String {
        guard let peer = draft.peers.first(where: { $0.id == peerID }) else { return "" }
        return peer[field]
    }

    func updatePeerValue(_ value: String, for peerID: UUID, field: PeerField) {
        guard let index = draft.peers.firstIndex(where: { $0.id == peerID }) else { return }
        draft.peers[index][field] = value
        peerErrorFieldsByID[peerID]?.remove(field)
    }

    func shouldAllowExcludePrivateIPs(for peerID: UUID) -> Bool {
        guard let peer = draft.peers.first(where: { $0.id == peerID }) else { return false }
        return AllowedIPHelpers.canToggleExcludePrivateIPs(
            peerAllowedIPs: peer.allowedIPs,
            peerCount: draft.peers.count
        )
    }

    func excludePrivateIPsValue(for peerID: UUID) -> Bool {
        guard draft.peers.count == 1,
              let peer = draft.peers.first(where: { $0.id == peerID }) else {
            return false
        }
        return AllowedIPHelpers.isExcludingPrivateIPs(allowedIPs: peer.allowedIPs)
    }

    func setExcludePrivateIPs(_ isOn: Bool, for peerID: UUID) {
        guard let index = draft.peers.firstIndex(where: { $0.id == peerID }) else { return }
        draft.peers[index].allowedIPs = AllowedIPHelpers.applyingExcludePrivateIPs(
            isOn,
            to: draft.peers[index].allowedIPs,
            dnsText: draft.interface.dns
        )
        peerErrorFieldsByID[peerID]?.remove(.allowedIPs)
    }

    func hasPeerError(for peerID: UUID, field: PeerField) -> Bool {
        peerErrorFieldsByID[peerID]?.contains(field) ?? false
    }

    func addPeer() {
        draft.peers.append(PeerDraft())
    }

    func deletePeer(id peerID: UUID) {
        draft.peers.removeAll { $0.id == peerID }
        peerErrorFieldsByID.removeValue(forKey: peerID)
    }

    struct ValidatedPayload: Equatable, Sendable {
        let profile: TunnelProfile
        let onDemandPolicy: OnDemandPolicy
        let postSaveNotice: AlertItem?
    }

    func buildValidatedPayload() -> Result<ValidatedPayload, AlertItem> {
        let validatedSplitDNS: SplitDNSConfiguration
        switch validateSplitDNSForSave() {
        case .failure(let alert):
            return .failure(alert)
        case .success(let config):
            validatedSplitDNS = config
        }

        switch draft.validate(splitDNS: validatedSplitDNS, options: .default) {
        case .failure(let error):
            interfaceErrorFields = error.interfaceFields
            peerErrorFieldsByID = error.peerFieldsByID
            return .failure(AlertItem(title: error.title, message: error.message))
        case .success(var profile):
            interfaceErrorFields = []
            peerErrorFieldsByID = [:]
            normalizeSSIDSettings()
            let (finalOptions, postSaveNotice) = resolvedKillSwitchOptions(for: profile)
            profile.options = finalOptions
            return .success(ValidatedPayload(
                profile: profile,
                onDemandPolicy: onDemandPolicy.normalized(),
                postSaveNotice: postSaveNotice
            ))
        }
    }

    @discardableResult
    func save(into store: TunnelStore) async -> Tunnel? {
        switch buildValidatedPayload() {
        case .failure(let alert):
            validationAlert = alert
            return nil
        case .success(let payload):
            isSaving = true
            defer { isSaving = false }
            do {
                let savedTunnel = try await store.saveTunnel(
                    existing: existingTunnel,
                    profile: payload.profile,
                    onDemandPolicy: payload.onDemandPolicy
                )
                if let notice = payload.postSaveNotice {
                    store.presentAlert(title: notice.title, message: notice.message)
                }
                return savedTunnel
            } catch {
                let tunnelError = store.wrapError(error, fallback: TunnelError.saveFailed)
                validationAlert = tunnelError.alertItem
                return nil
            }
        }
    }

    private func loadInitialState() {
        previousDNSValue = draft.interface.dns

        let policy = existingTunnel?.onDemandPolicy ?? .off
        isCellularOnDemandEnabled = policy.cellular
        isWiFiOnDemandEnabled = policy.wifi
        ssidOption = policy.ssidOptionKind
        selectedSSIDs = policy.selectedSSIDs

        let existingSplitDNS = existingTunnel?.splitDNS ?? .allDomains
        splitDNSMode = existingSplitDNS.mode
        splitDNSDomains = existingSplitDNS.domains
        splitDNSExclusions = existingSplitDNS.exclusions
        newSplitDNSDomain = ""
        splitDNSInputError = nil
        newSplitDNSExclusion = ""
        splitDNSExclusionInputError = nil

        let existingOptions = existingTunnel?.options ?? .default
        isKillSwitchEnabled = existingOptions.killSwitch.isEnabled
        allowLocalNetworkWithKillSwitch = existingOptions.killSwitch.allowLocalNetwork
    }
}

extension TunnelEditorViewModel {
    var onDemandPolicy: OnDemandPolicy {
        let filter: OnDemandPolicy.SSIDFilter
        if isWiFiOnDemandEnabled {
            switch ssidOption {
            case .any:
                filter = .any
            case .only:
                filter = .only(selectedSSIDs)
            case .except:
                filter = .except(selectedSSIDs)
            }
        } else {
            filter = .any
        }
        return OnDemandPolicy(
            cellular: isCellularOnDemandEnabled,
            wifi: isWiFiOnDemandEnabled,
            ssidFilter: filter
        )
    }

    var onDemandSSIDSummary: String {
        onDemandPolicy.ssidDescription
    }

    func normalizeSSIDSettings() {
        let normalized = onDemandPolicy.normalized()
        isCellularOnDemandEnabled = normalized.cellular
        isWiFiOnDemandEnabled = normalized.wifi
        ssidOption = normalized.ssidOptionKind
        selectedSSIDs = normalized.selectedSSIDs
    }

    var isOnDemandConfigured: Bool {
        isCellularOnDemandEnabled || isWiFiOnDemandEnabled
    }

    var routesAllIPv4Traffic: Bool {
        TunnelProfile.routesAllIPv4Traffic(allowedIPs: currentAllowedIPs)
    }

    var routesAllIPv6Traffic: Bool {
        TunnelProfile.routesAllIPv6Traffic(allowedIPs: currentAllowedIPs)
    }

    var tunnelOptions: TunnelOptions {
        guard isKillSwitchEnabled, routesAllIPv4Traffic else {
            return .default
        }
        return TunnelOptions(
            killSwitch: TunnelOptions.KillSwitch(
                isEnabled: true,
                allowLocalNetwork: allowLocalNetworkWithKillSwitch
            )
        )
    }

    func resolvedKillSwitchOptions(for profile: TunnelProfile) -> (TunnelOptions, AlertItem?) {
        if isKillSwitchEnabled && !profile.routesAllIPv4Traffic {
            isKillSwitchEnabled = false
            allowLocalNetworkWithKillSwitch = false
            let notice = AlertItem(
                title: "Kill Switch Turned Off",
                message: "The kill switch was turned off because this tunnel no longer routes all IPv4 traffic (0.0.0.0/0)."
            )
            return (.default, notice)
        }
        let options = TunnelOptions(
            killSwitch: TunnelOptions.KillSwitch(
                isEnabled: isKillSwitchEnabled,
                allowLocalNetwork: isKillSwitchEnabled ? allowLocalNetworkWithKillSwitch : false
            )
        )
        return (options, nil)
    }

    static func fetchConnectedSSID() async -> String? {
        #if targetEnvironment(simulator)
        return "Simulator Wi-Fi"
        #else
        return await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
        #endif
    }
}
