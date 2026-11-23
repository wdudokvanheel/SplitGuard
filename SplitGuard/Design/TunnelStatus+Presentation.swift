import SwiftUI

extension TunnelStatus {
    var displayTitle: String {
        switch self {
        case .inactive:
            return tr("tunnelStatusInactive")
        case .activating:
            return tr("tunnelStatusActivating")
        case .active:
            return tr("tunnelStatusActive")
        case .deactivating:
            return tr("tunnelStatusDeactivating")
        case .reasserting:
            return tr("tunnelStatusReasserting")
        case .restarting:
            return tr("tunnelStatusRestarting")
        case .waiting:
            return tr("tunnelStatusWaiting")
        }
    }

    var statusColor: Color {
        switch self {
        case .active:
            return SGColor.statusActive
        case .activating, .deactivating, .reasserting, .restarting, .waiting:
            return SGColor.statusTransitioning
        case .inactive:
            return SGColor.statusInactive
        }
    }

    var isTransitioning: Bool {
        switch self {
        case .activating, .deactivating, .reasserting, .restarting, .waiting:
            return true
        case .active, .inactive:
            return false
        }
    }

    var isActiveOrConnecting: Bool {
        switch self {
        case .active, .activating, .reasserting, .restarting:
            return true
        case .inactive, .deactivating, .waiting:
            return false
        }
    }

    var symbolName: String {
        switch self {
        case .active:
            return "checkmark.shield.fill"
        case .activating, .reasserting, .restarting, .waiting:
            return "arrow.triangle.2.circlepath"
        case .deactivating:
            return "shield.slash"
        case .inactive:
            return "shield"
        }
    }
}

struct TunnelDisplayState: Equatable {
    let status: TunnelStatus
    let hasOnDemandRules: Bool
    let isOnDemandEnabled: Bool

    var isSwitchOn: Bool {
        status == .activating || status == .active || isOnDemandEnabled
    }

    var isSwitchInteractive: Bool {
        if hasOnDemandRules {
            return true
        }
        return status == .inactive || status == .active
    }

    var switchTint: Color {
        if isOnDemandEnabled && !(status == .activating || status == .active) {
            return SGColor.statusOnDemand
        }
        return SGColor.statusActive
    }

    var statusColor: Color {
        if isOnDemandEnabled && status == .inactive {
            return SGColor.statusOnDemand
        }
        return status.statusColor
    }

    var heroBannerColor: Color {
        switch status {
        case .active:
            return SGColor.popGreen
        case .deactivating:
            return SGColor.popRed
        case .activating, .reasserting, .restarting, .waiting:
            return SGColor.popYellow
        case .inactive:
            return isOnDemandEnabled ? SGColor.popYellow : SGColor.popBlue
        }
    }

    var isInactiveBadge: Bool {
        status == .inactive && !isOnDemandEnabled
    }

    var statusText: String {
        if hasOnDemandRules && !isOnDemandEnabled && status == .inactive {
            return tr("tunnelStatusOnDemandDisabled")
        }
        if hasOnDemandRules && isOnDemandEnabled {
            return status.displayTitle + tr("tunnelStatusAddendumOnDemand")
        }
        return status.displayTitle
    }
}
