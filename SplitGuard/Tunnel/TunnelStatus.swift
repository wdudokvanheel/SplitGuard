// SPDX-License-Identifier: MIT

import Foundation
import NetworkExtension

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
