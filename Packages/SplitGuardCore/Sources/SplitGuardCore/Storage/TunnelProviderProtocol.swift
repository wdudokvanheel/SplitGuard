// SPDX-License-Identifier: MIT

import Foundation
import NetworkExtension

public extension NETunnelProviderProtocol {
    /// Key of the persisted tunnel ID in `providerConfiguration`.
    ///
    /// The ID is device-local: it is not part of the wg-quick text, so exports and
    /// imported copies never share it.
    static let tunnelIDKey = "id"

    /// Key of the encoded `TunnelLocalSettings` JSON blob in `providerConfiguration`.
    static let localSettingsKey = "localSettings"

    /// The single builder for SplitGuard protocol configurations. Every path that
    /// creates a tunnel configuration goes through here, so none can drop the ID.
    convenience init(
        profile: TunnelProfile,
        passwordReference: Data,
        providerBundleIdentifier: String,
        tunnelID: UUID,
        localSettings: TunnelLocalSettings = .default
    ) {
        self.init()
        self.providerBundleIdentifier = providerBundleIdentifier
        self.passwordReference = passwordReference
        self.serverAddress = ProfileStore.serverAddress(for: profile)
        var configuration: [String: Any] = [Self.tunnelIDKey: tunnelID.uuidString]
        if !localSettings.isDefault, let encoded = try? JSONEncoder().encode(localSettings) {
            configuration[Self.localSettingsKey] = encoded
        }
        self.providerConfiguration = configuration
        applyKillSwitch(profile.options.sanitized(for: profile))
    }

    /// The persisted tunnel ID, or `nil` for a configuration written without one.
    var tunnelID: UUID? {
        (providerConfiguration?[Self.tunnelIDKey] as? String).flatMap(UUID.init(uuidString:))
    }

    /// Stores `id` while keeping any other `providerConfiguration` entries.
    func setTunnelID(_ id: UUID) {
        var configuration = providerConfiguration ?? [:]
        configuration[Self.tunnelIDKey] = id.uuidString
        providerConfiguration = configuration
    }

    /// Device-local settings for this tunnel, falling back to `.default` if absent or unreadable.
    var localSettings: TunnelLocalSettings {
        guard let data = providerConfiguration?[Self.localSettingsKey] as? Data,
              let decoded = try? JSONDecoder().decode(TunnelLocalSettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    /// Stores device-local settings while keeping any other `providerConfiguration` entries.
    func setLocalSettings(_ settings: TunnelLocalSettings) {
        var configuration = providerConfiguration ?? [:]
        if settings.isDefault {
            configuration.removeValue(forKey: Self.localSettingsKey)
        } else if let encoded = try? JSONEncoder().encode(settings) {
            configuration[Self.localSettingsKey] = encoded
        }
        providerConfiguration = configuration.isEmpty ? nil : configuration
    }

    func applyKillSwitch(_ options: TunnelOptions) {
        if options.killSwitch.isEnabled {
            includeAllNetworks = true
            excludeLocalNetworks = options.killSwitch.allowLocalNetwork
        } else {
            includeAllNetworks = false
            excludeLocalNetworks = false
        }
        if #available(iOS 16.4, macOS 13.3, *) {
            excludeCellularServices = true
            excludeAPNs = true
        }
        if #available(iOS 17.4, macOS 14.4, *) {
            excludeDeviceCommunication = true
        }
    }
}
