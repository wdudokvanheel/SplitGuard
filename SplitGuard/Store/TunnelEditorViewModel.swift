// SPDX-License-Identifier: MIT

import Foundation
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

    var isHealthAlertsEnabled = false
    var healthAlertDelaySeconds = TunnelLocalSettings.HealthAlerts.defaultDelaySeconds
    private(set) var notificationAuthorizationState: HealthAlertAuthorizationState = .notDetermined

    var selectedSection: TunnelEditorSection = .interface
    var validationAlert: AlertItem?
    var isSaving = false

    private let permissionManager: any HealthAlertPermissionManaging
    private var previousDNSValue = ""

    init(
        tunnel: Tunnel? = nil,
        permissionManager: any HealthAlertPermissionManaging = SystemHealthAlertPermissionManager()
    ) {
        self.existingTunnel = tunnel
        self.permissionManager = permissionManager
        self.draft = tunnel.map { TunnelDraft(profile: $0.profile) } ?? TunnelDraft()

        loadInitialState()
    }

    var isEditing: Bool {
        existingTunnel != nil
    }

    var navigationTitle: String {
        isEditing
            ? L10n.tr("tunnel.editor.editTitle", defaultValue: "Edit configuration")
            : L10n.tr("tunnel.editor.newTitle", defaultValue: "New configuration")
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
        let localSettings: TunnelLocalSettings
        let postSaveNotice: AlertItem?
    }

    func buildValidatedPayload() -> Result<ValidatedPayload, AlertItem> {
        let validatedSplitDNS: SplitDNSConfiguration
        switch validateSplitDNSForSave() {
        case .failure(let alert):
            selectedSection = .dns
            return .failure(alert)
        case .success(let config):
            validatedSplitDNS = config
        }

        switch draft.validate(splitDNS: validatedSplitDNS, options: .default) {
        case .failure(let error):
            interfaceErrorFields = error.interfaceFields
            peerErrorFieldsByID = error.peerFieldsByID
            if let section = firstSectionWithErrors {
                selectedSection = section
            }
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
                localSettings: localSettings,
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
                    onDemandPolicy: payload.onDemandPolicy,
                    localSettings: payload.localSettings
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

        let existingLocalSettings = existingTunnel?.localSettings ?? .default
        isHealthAlertsEnabled = existingLocalSettings.healthAlerts.isEnabled
        healthAlertDelaySeconds = existingLocalSettings.healthAlerts.delaySeconds
    }
}

extension TunnelEditorViewModel {
    var localSettings: TunnelLocalSettings {
        TunnelLocalSettings(
            healthAlerts: TunnelLocalSettings.HealthAlerts(
                isEnabled: isHealthAlertsEnabled,
                delaySeconds: healthAlertDelaySeconds
            )
        )
    }

    func refreshNotificationAuthorization() async {
        notificationAuthorizationState = await permissionManager.authorizationState()
    }

    func setHealthAlertsEnabled(_ enabled: Bool) async {
        isHealthAlertsEnabled = enabled
        if enabled {
            notificationAuthorizationState = await permissionManager.requestAuthorization()
        }
    }
}
