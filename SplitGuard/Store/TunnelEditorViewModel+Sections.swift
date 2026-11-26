// SPDX-License-Identifier: MIT

import Foundation

enum TunnelEditorSection: String, CaseIterable, Hashable, Sendable {
    case interface
    case peers
    case dns
    case behavior

    var title: String {
        switch self {
        case .interface:
            return L10n.tr("tunnel.editor.tab.interface", defaultValue: "Interface")
        case .peers:
            return L10n.tr("tunnel.editor.tab.peers", defaultValue: "Peers")
        case .dns:
            return L10n.tr("tunnel.editor.tab.dns", defaultValue: "DNS")
        case .behavior:
            return L10n.tr("tunnel.editor.tab.behavior", defaultValue: "Behavior")
        }
    }
}

extension TunnelEditorViewModel {
    func hasErrors(in section: TunnelEditorSection) -> Bool {
        switch section {
        case .interface:
            return !interfaceErrorFields.subtracting([.dns]).isEmpty
        case .peers:
            return peerErrorFieldsByID.values.contains { !$0.isEmpty }
        case .dns:
            return interfaceErrorFields.contains(.dns)
        case .behavior:
            return false
        }
    }

    var firstSectionWithErrors: TunnelEditorSection? {
        TunnelEditorSection.allCases.first { hasErrors(in: $0) }
    }

    func hasAdvancedPeerValues(for peerID: UUID) -> Bool {
        guard let peer = draft.peers.first(where: { $0.id == peerID }) else { return false }
        return !peer.presharedKey.isEmpty || !peer.persistentKeepalive.isEmpty
    }

    var hasAdvancedInterfaceValues: Bool {
        !draft.interface.listenPort.isEmpty || !draft.interface.mtu.isEmpty
    }
}
