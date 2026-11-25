// SPDX-License-Identifier: MIT

import Foundation
import NetworkExtension
import SplitGuardCore

enum TunnelStatus: Equatable, Hashable, Sendable {
    case inactive
    case activating
    case active
    case deactivating
    case reasserting
    case restarting
    case waiting

    init(from neStatus: NEVPNStatus) {
        switch neStatus {
        case .connected:
            self = .active
        case .connecting:
            self = .activating
        case .disconnected:
            self = .inactive
        case .disconnecting:
            self = .deactivating
        case .reasserting:
            self = .reasserting
        case .invalid:
            self = .inactive
        @unknown default:
            self = .inactive
        }
    }

    init(snapshotStatus: TunnelSnapshotStatus) {
        switch snapshotStatus {
        case .inactive:
            self = .inactive
        case .activating:
            self = .activating
        case .active:
            self = .active
        case .deactivating:
            self = .deactivating
        case .reasserting:
            self = .reasserting
        case .restarting:
            self = .restarting
        case .waiting:
            self = .waiting
        }
    }

    var snapshotStatus: TunnelSnapshotStatus {
        switch self {
        case .inactive:
            return .inactive
        case .activating:
            return .activating
        case .active:
            return .active
        case .deactivating:
            return .deactivating
        case .reasserting:
            return .reasserting
        case .restarting:
            return .restarting
        case .waiting:
            return .waiting
        }
    }
}

extension TunnelStatus: CustomDebugStringConvertible {
    var debugDescription: String {
        switch self {
        case .inactive:
            return "inactive"
        case .activating:
            return "activating"
        case .active:
            return "active"
        case .deactivating:
            return "deactivating"
        case .reasserting:
            return "reasserting"
        case .restarting:
            return "restarting"
        case .waiting:
            return "waiting"
        }
    }
}
