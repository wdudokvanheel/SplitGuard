// SPDX-License-Identifier: MIT

import Foundation

public struct TunnelOptions: Codable, Equatable, Hashable, Sendable {
    public struct KillSwitch: Codable, Equatable, Hashable, Sendable {
        public var isEnabled: Bool
        public var allowLocalNetwork: Bool

        public init(isEnabled: Bool = false, allowLocalNetwork: Bool = false) {
            self.isEnabled = isEnabled
            self.allowLocalNetwork = allowLocalNetwork
        }
    }

    public var killSwitch: KillSwitch

    public static let `default` = TunnelOptions()

    public init(killSwitch: KillSwitch = KillSwitch()) {
        self.killSwitch = killSwitch
    }

    public var isDefault: Bool {
        !killSwitch.isEnabled && !killSwitch.allowLocalNetwork
    }

    public func sanitized(routesAllIPv4: Bool) -> TunnelOptions {
        guard routesAllIPv4, killSwitch.isEnabled else {
            return .default
        }
        return self
    }

    public func sanitized(for profile: TunnelProfile) -> TunnelOptions {
        sanitized(routesAllIPv4: profile.routesAllIPv4Traffic)
    }
}
