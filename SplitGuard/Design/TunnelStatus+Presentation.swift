import SwiftUI
import WireGuardEngine

enum KillSwitchBlockState: Equatable, Sendable {
    case noNetwork
    case serverUnreachable

    var displayText: String {
        switch self {
        case .noNetwork:
            return "Blocking traffic — no network"
        case .serverUnreachable:
            return "Blocking traffic — server unreachable"
        }
    }

    var detailMessage: String {
        switch self {
        case .noNetwork:
            return "No network connection. Traffic is blocked by the kill switch."
        case .serverUnreachable:
            return "Server unreachable. Traffic is blocked by the kill switch."
        }
    }

    static func evaluate(killSwitchEnabled: Bool, deviceStatus: DeviceStatus?) -> KillSwitchBlockState? {
        guard killSwitchEnabled, let deviceStatus else { return nil }
        if case .paused = deviceStatus.state {
            return .noNetwork
        }
        guard deviceStatus.state == .up else { return nil }
        let hasWorkingOrIdlePeer = deviceStatus.peers.contains {
            $0.health == .healthy || $0.health == .idle
        }
        return hasWorkingOrIdlePeer ? nil : .serverUnreachable
    }
}

enum TunnelHealthState: Equatable, Sendable {
    case blocking(KillSwitchBlockState)
    case noHandshake(attempts: Int)
    case stalled
    case connecting
    case idle
    case healthy

    init(peer: PeerStatus) {
        switch peer.health {
        case .connecting:
            self = .connecting
        case .noHandshake:
            self = .noHandshake(attempts: peer.handshakeAttempts)
        case .stalled:
            self = .stalled
        case .idle:
            self = .idle
        case .healthy:
            self = .healthy
        }
    }

    /// Combines multiple peers into one tunnel health value:
    /// the worst peer that is not idle, or idle if all peers are idle.
    static func combine(peers: [PeerStatus]) -> TunnelHealthState? {
        guard !peers.isEmpty else { return nil }
        let noHandshakePeers = peers.filter { $0.health == .noHandshake }
        if !noHandshakePeers.isEmpty {
            let maxAttempts = noHandshakePeers.map(\.handshakeAttempts).max() ?? 0
            return .noHandshake(attempts: maxAttempts)
        }
        if peers.contains(where: { $0.health == .stalled }) {
            return .stalled
        }
        if peers.contains(where: { $0.health == .connecting }) {
            return .connecting
        }
        if peers.contains(where: { $0.health == .healthy }) {
            return .healthy
        }
        return .idle
    }

    static func evaluate(killSwitchEnabled: Bool, deviceStatus: DeviceStatus?) -> TunnelHealthState? {
        guard let deviceStatus else { return nil }
        if let blockState = KillSwitchBlockState.evaluate(
            killSwitchEnabled: killSwitchEnabled,
            deviceStatus: deviceStatus
        ) {
            return .blocking(blockState)
        }
        guard deviceStatus.state == .up else { return nil }
        return combine(peers: deviceStatus.peers)
    }

    var shortLabel: String {
        switch self {
        case .blocking(let state):
            return state.displayText
        case .connecting:
            return "Connecting"
        case .noHandshake:
            return "No handshake"
        case .stalled:
            return "Stalled"
        case .idle:
            return "Idle"
        case .healthy:
            return "Healthy"
        }
    }

    var detailMessage: String? {
        switch self {
        case .blocking(let state):
            return state.detailMessage
        case .connecting:
            return "No handshake yet."
        case .noHandshake(let attempts):
            if attempts > 0 {
                let word = attempts == 1 ? "attempt" : "attempts"
                return "No response after \(attempts) handshake \(word). "
                    + "Usual causes: a wrong key, a wrong endpoint, or a blocked port."
            }
            return "No handshake response. Usual causes: a wrong key, a wrong endpoint, or a blocked port."
        case .stalled:
            return "Sent traffic gets no answer."
        case .idle:
            return "No traffic. This is normal without persistent keepalive."
        case .healthy:
            return nil
        }
    }

    var isProblem: Bool {
        switch self {
        case .blocking, .noHandshake, .stalled:
            return true
        case .connecting, .idle, .healthy:
            return false
        }
    }

    var isNeutral: Bool {
        self == .idle
    }

    var isAnimated: Bool {
        self == .connecting
    }

    var badgeColor: Color {
        switch self {
        case .blocking, .noHandshake, .stalled:
            return SGColor.popRed
        case .connecting:
            return SGColor.popYellow
        case .idle:
            return SGColor.surfaceElevated
        case .healthy:
            return SGColor.popGreen
        }
    }

    var heroBannerColor: Color {
        switch self {
        case .blocking, .noHandshake, .stalled:
            return SGColor.popRed
        case .connecting:
            return SGColor.popYellow
        case .idle, .healthy:
            return SGColor.popGreen
        }
    }
}

extension TunnelStatus {
    var displayTitle: String {
        switch self {
        case .inactive:
            return String(localized: "tunnel.status.inactive", defaultValue: "Inactive")
        case .activating:
            return String(localized: "tunnel.status.activating", defaultValue: "Activating")
        case .active:
            return String(localized: "tunnel.status.active", defaultValue: "Active")
        case .deactivating:
            return String(localized: "tunnel.status.deactivating", defaultValue: "Deactivating")
        case .reasserting:
            return String(localized: "tunnel.status.reasserting", defaultValue: "Reactivating")
        case .restarting:
            return String(localized: "tunnel.status.restarting", defaultValue: "Restarting")
        case .waiting:
            return String(localized: "tunnel.status.waiting", defaultValue: "Waiting")
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
    var healthState: TunnelHealthState?

    init(
        status: TunnelStatus,
        hasOnDemandRules: Bool,
        isOnDemandEnabled: Bool,
        healthState: TunnelHealthState? = nil
    ) {
        self.status = status
        self.hasOnDemandRules = hasOnDemandRules
        self.isOnDemandEnabled = isOnDemandEnabled
        self.healthState = healthState
    }

    init(
        status: TunnelStatus,
        hasOnDemandRules: Bool,
        isOnDemandEnabled: Bool,
        killSwitchBlockState: KillSwitchBlockState?
    ) {
        self.init(
            status: status,
            hasOnDemandRules: hasOnDemandRules,
            isOnDemandEnabled: isOnDemandEnabled,
            healthState: killSwitchBlockState.map(TunnelHealthState.blocking)
        )
    }

    var killSwitchBlockState: KillSwitchBlockState? {
        if case .blocking(let state) = healthState {
            return state
        }
        return nil
    }

    var activeHealthState: TunnelHealthState? {
        status == .active ? healthState : nil
    }

    var secondaryHealthBadgeState: TunnelHealthState? {
        guard let activeHealthState else { return nil }
        if case .blocking = activeHealthState {
            return nil
        }
        return activeHealthState
    }

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
        if let activeHealthState, activeHealthState.isProblem {
            return SGColor.statusError
        }
        return SGColor.statusActive
    }

    var statusColor: Color {
        if let activeHealthState {
            if activeHealthState.isProblem {
                return SGColor.statusError
            }
            if activeHealthState == .connecting {
                return SGColor.statusTransitioning
            }
        }
        if isOnDemandEnabled && status == .inactive {
            return SGColor.statusOnDemand
        }
        return status.statusColor
    }

    var heroBannerColor: Color {
        switch status {
        case .active:
            return healthState?.heroBannerColor ?? SGColor.popGreen
        case .deactivating:
            return SGColor.popRed
        case .activating, .reasserting, .restarting, .waiting:
            return SGColor.popYellow
        case .inactive:
            return isOnDemandEnabled ? SGColor.popYellow : SGColor.popPurple
        }
    }

    var isInactiveBadge: Bool {
        status == .inactive && !isOnDemandEnabled
    }

    var statusText: String {
        if status == .active, let killSwitchBlockState {
            return killSwitchBlockState.displayText
        }
        if hasOnDemandRules && !isOnDemandEnabled && status == .inactive {
            return String(localized: "tunnel.status.onDemandDisabled", defaultValue: "On-Demand Disabled")
        }
        if hasOnDemandRules && isOnDemandEnabled {
            return String(
                localized: "tunnel.status.onDemandFormat",
                defaultValue: "\(status.displayTitle) (On-Demand)"
            )
        }
        return status.displayTitle
    }
}
