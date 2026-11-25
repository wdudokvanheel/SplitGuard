// SPDX-License-Identifier: MIT

import Foundation

/// Device-local per-tunnel settings stored in `NETunnelProviderProtocol.providerConfiguration`.
///
/// Unlike `TunnelOptions` and `SplitDNSConfiguration`, these settings only control what
/// this device records or notifies about and are never written into exported wg-quick text.
public struct TunnelLocalSettings: Codable, Equatable, Hashable, Sendable {
    public struct HealthAlerts: Codable, Equatable, Hashable, Sendable {
        public static let defaultDelaySeconds: Int = 120
        public static let minimumDelaySeconds: Int = 15
        public static let supportedDelaySeconds: [Int] = [30, 60, 120, 300]

        public var isEnabled: Bool
        public var delaySeconds: Int

        public init(isEnabled: Bool = false, delaySeconds: Int = defaultDelaySeconds) {
            self.isEnabled = isEnabled
            self.delaySeconds = max(Self.minimumDelaySeconds, delaySeconds)
        }

        private enum CodingKeys: String, CodingKey {
            case isEnabled
            case delaySeconds
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let enabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
            let delay = try container.decodeIfPresent(Int.self, forKey: .delaySeconds) ?? Self.defaultDelaySeconds
            self.init(isEnabled: enabled, delaySeconds: delay)
        }
    }

    public var healthAlerts: HealthAlerts

    public static let `default` = TunnelLocalSettings()

    public init(healthAlerts: HealthAlerts = HealthAlerts()) {
        self.healthAlerts = healthAlerts
    }

    public var isDefault: Bool {
        !healthAlerts.isEnabled && healthAlerts.delaySeconds == HealthAlerts.defaultDelaySeconds
    }

    private enum CodingKeys: String, CodingKey {
        case healthAlerts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let alerts = try container.decodeIfPresent(HealthAlerts.self, forKey: .healthAlerts) ?? HealthAlerts()
        self.init(healthAlerts: alerts)
    }
}
