import Foundation
import NetworkExtension
import Observation
import WireGuardKit

struct EditablePeerItem: Identifiable, Equatable {
    let id: UUID
    var index: Int
}

@MainActor
@Observable
final class TunnelEditorViewModel {
    let existingTunnel: TunnelContainer?

    var name = ""
    var privateKey = ""
    var publicKey = ""
    var addresses = ""
    var listenPort = ""
    var mtu = ""
    var dns = ""

    private(set) var peerItems: [EditablePeerItem] = []
    private(set) var interfaceErrorFields: Set<TunnelViewModel.InterfaceField> = []
    private(set) var peerErrorFieldsByID: [UUID: Set<TunnelViewModel.PeerField>] = [:]
    private(set) var peerRevision = 0

    var isCellularOnDemandEnabled = false
    var isWiFiOnDemandEnabled = false
    var ssidOption: ActivateOnDemandViewModel.OnDemandSSIDOption = .anySSID
    var selectedSSIDs: [String] = []

    var validationAlert: AlertItem?
    var isSaving = false

    private let tunnelViewModel: TunnelViewModel
    private let onDemandViewModel: ActivateOnDemandViewModel
    private var previousDNSValue = ""

    init(tunnel: TunnelContainer? = nil) {
        self.existingTunnel = tunnel
        self.tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnel?.tunnelConfiguration)
        self.onDemandViewModel = tunnel.map(ActivateOnDemandViewModel.init(tunnel:)) ?? ActivateOnDemandViewModel()

        loadInitialState()
    }

    var isEditing: Bool {
        existingTunnel != nil
    }

    var navigationTitle: String {
        isEditing ? tr("editTunnelViewTitle") : tr("newTunnelViewTitle")
    }

    var shouldStronglyRecommendDNS: Bool {
        _ = peerRevision
        return tunnelViewModel.peersData.contains { $0.shouldStronglyRecommendDNS }
    }

    var onDemandSSIDSummary: String {
        syncOnDemandToModel()
        return onDemandViewModel.localizedSSIDDescription
    }

    func updateName(_ value: String) {
        name = value
        tunnelViewModel.interfaceData[.name] = value
        interfaceErrorFields.remove(.name)
    }

    func updatePrivateKey(_ value: String) {
        privateKey = value
        tunnelViewModel.interfaceData[.privateKey] = value
        publicKey = tunnelViewModel.interfaceData[.publicKey]
        interfaceErrorFields.remove(.privateKey)
    }

    func generateKeyPair() {
        let newKey = PrivateKey().base64Key
        updatePrivateKey(newKey)
    }

    func updateAddresses(_ value: String) {
        addresses = value
        tunnelViewModel.interfaceData[.addresses] = value
        interfaceErrorFields.remove(.addresses)
    }

    func updateListenPort(_ value: String) {
        listenPort = value
        tunnelViewModel.interfaceData[.listenPort] = value
        interfaceErrorFields.remove(.listenPort)
    }

    func updateMTU(_ value: String) {
        mtu = value
        tunnelViewModel.interfaceData[.mtu] = value
        interfaceErrorFields.remove(.mtu)
    }

    func updateDNS(_ value: String) {
        let oldValue = previousDNSValue
        dns = value
        tunnelViewModel.interfaceData[.dns] = value
        interfaceErrorFields.remove(.dns)
        if tunnelViewModel.updateDNSServersInAllowedIPsIfRequired(oldDNSServers: oldValue, newDNSServers: value) {
            peerRevision += 1
        }
        previousDNSValue = value
    }

    func peerValue(for peerID: UUID, field: TunnelViewModel.PeerField) -> String {
        _ = peerRevision
        guard let peerData = peerData(for: peerID) else { return "" }
        return peerData[field]
    }

    func updatePeerValue(_ value: String, for peerID: UUID, field: TunnelViewModel.PeerField) {
        guard let peerData = peerData(for: peerID) else { return }
        peerData[field] = value
        peerErrorFieldsByID[peerID]?.remove(field)
        peerRevision += 1
    }

    func shouldAllowExcludePrivateIPs(for peerID: UUID) -> Bool {
        _ = peerRevision
        return peerData(for: peerID)?.shouldAllowExcludePrivateIPsControl ?? false
    }

    func excludePrivateIPsValue(for peerID: UUID) -> Bool {
        _ = peerRevision
        return peerData(for: peerID)?.excludePrivateIPsValue ?? false
    }

    func setExcludePrivateIPs(_ isOn: Bool, for peerID: UUID) {
        guard let peerData = peerData(for: peerID) else { return }
        peerData.excludePrivateIPsValueChanged(isOn: isOn, dnsServers: tunnelViewModel.interfaceData[.dns])
        peerRevision += 1
    }

    func hasPeerError(for peerID: UUID, field: TunnelViewModel.PeerField) -> Bool {
        peerErrorFieldsByID[peerID]?.contains(field) ?? false
    }

    func addPeer() {
        tunnelViewModel.appendEmptyPeer()
        let newIndex = tunnelViewModel.peersData.count - 1
        peerItems.append(EditablePeerItem(id: UUID(), index: newIndex))
        peerRevision += 1
    }

    func deletePeer(id peerID: UUID) {
        guard let itemIndex = peerItems.firstIndex(where: { $0.id == peerID }),
              itemIndex < tunnelViewModel.peersData.count else { return }
        let peerData = tunnelViewModel.peersData[itemIndex]
        tunnelViewModel.deletePeer(peer: peerData)
        peerItems.remove(at: itemIndex)
        peerErrorFieldsByID.removeValue(forKey: peerID)
        for idx in peerItems.indices {
            peerItems[idx].index = idx
        }
        peerRevision += 1
    }

    func normalizeSSIDSettings() {
        syncOnDemandToModel()
        onDemandViewModel.fixSSIDOption()
        ssidOption = onDemandViewModel.ssidOption
        selectedSSIDs = onDemandViewModel.selectedSSIDs
    }

    func buildValidatedPayload() -> Result<(TunnelConfiguration, ActivateOnDemandOption), AlertItem> {
        let saveResult = tunnelViewModel.save()
        syncValidationErrors()

        switch saveResult {
        case .error(let errorMessage):
            let isInterfaceInvalid = tunnelViewModel.interfaceData.validatedConfiguration == nil ||
                tunnelViewModel.interfaceData.validatedName == nil
            let title = isInterfaceInvalid ? tr("alertInvalidInterfaceTitle") : tr("alertInvalidPeerTitle")
            return .failure(AlertItem(title: title, message: errorMessage))
        case .saved(let configuration):
            normalizeSSIDSettings()
            let onDemandOption = onDemandViewModel.toOnDemandOption()
            return .success((configuration, onDemandOption))
        }
    }

    func save(into store: TunnelStore, onSuccess: @escaping (TunnelContainer) -> Void) {
        switch buildValidatedPayload() {
        case .failure(let alert):
            validationAlert = alert
        case .success(let (configuration, onDemandOption)):
            isSaving = true
            store.saveTunnel(
                existing: existingTunnel,
                configuration: configuration,
                onDemandOption: onDemandOption
            ) { [weak self] result in
                guard let self else { return }
                self.isSaving = false
                switch result {
                case .success(let savedTunnel):
                    onSuccess(savedTunnel)
                case .failure(let error):
                    let alert = error.alertText
                    self.validationAlert = AlertItem(title: alert.title, message: alert.message)
                }
            }
        }
    }

    private func loadInitialState() {
        let interfaceData = tunnelViewModel.interfaceData
        name = interfaceData[.name]
        privateKey = interfaceData[.privateKey]
        publicKey = interfaceData[.publicKey]
        addresses = interfaceData[.addresses]
        listenPort = interfaceData[.listenPort]
        mtu = interfaceData[.mtu]
        dns = interfaceData[.dns]
        previousDNSValue = dns

        peerItems = tunnelViewModel.peersData.indices.map { index in
            EditablePeerItem(id: UUID(), index: index)
        }

        isCellularOnDemandEnabled = onDemandViewModel.isNonWiFiInterfaceEnabled
        isWiFiOnDemandEnabled = onDemandViewModel.isWiFiInterfaceEnabled
        ssidOption = onDemandViewModel.ssidOption
        selectedSSIDs = onDemandViewModel.selectedSSIDs
    }

    private func peerData(for peerID: UUID) -> TunnelViewModel.PeerData? {
        guard let item = peerItems.first(where: { $0.id == peerID }),
              item.index >= 0,
              item.index < tunnelViewModel.peersData.count else {
            return nil
        }
        return tunnelViewModel.peersData[item.index]
    }

    private func syncOnDemandToModel() {
        onDemandViewModel.isNonWiFiInterfaceEnabled = isCellularOnDemandEnabled
        onDemandViewModel.isWiFiInterfaceEnabled = isWiFiOnDemandEnabled
        onDemandViewModel.ssidOption = ssidOption
        onDemandViewModel.selectedSSIDs = selectedSSIDs
    }

    private func syncValidationErrors() {
        interfaceErrorFields = tunnelViewModel.interfaceData.fieldsWithError
        var updatedPeerErrors: [UUID: Set<TunnelViewModel.PeerField>] = [:]
        for item in peerItems where item.index < tunnelViewModel.peersData.count {
            let errors = tunnelViewModel.peersData[item.index].fieldsWithError
            if !errors.isEmpty {
                updatedPeerErrors[item.id] = errors
            }
        }
        peerErrorFieldsByID = updatedPeerErrors
        peerRevision += 1
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
