// SPDX-License-Identifier: MIT

import Foundation
import enum SplitGuardCore.AppGroup
import enum SplitGuardCore.Log

/// Most recently activated tunnels, newest first, keyed by the persisted tunnel ID.
enum RecentTunnelsTracker {
    private static let keyRecentlyActivatedTunnelIDs = "recentlyActivatedTunnelIDs"
    private static let maxNumberOfTunnels = 10

    private static func resolveUserDefaults(_ override: UserDefaults?) -> UserDefaults? {
        if let override {
            return override
        }
        guard let appGroupID = AppGroup.identifier() else {
            Log.error("Cannot obtain app group ID from bundle for tracking recently used tunnels")
            return nil
        }
        guard let sharedDefaults = UserDefaults(suiteName: appGroupID) else {
            Log.error("Cannot obtain shared user defaults for tracking recently used tunnels")
            return nil
        }
        return sharedDefaults
    }

    private static func storedIDs(in defaults: UserDefaults) -> [UUID] {
        (defaults.stringArray(forKey: keyRecentlyActivatedTunnelIDs) ?? []).compactMap(UUID.init(uuidString:))
    }

    private static func store(_ ids: [UUID], in defaults: UserDefaults) {
        defaults.set(ids.map(\.uuidString), forKey: keyRecentlyActivatedTunnelIDs)
    }

    static func handleTunnelActivated(tunnelID: UUID, userDefaults: UserDefaults? = nil) {
        guard let defaults = resolveUserDefaults(userDefaults) else { return }
        var recentTunnels = storedIDs(in: defaults)
        recentTunnels.removeAll { $0 == tunnelID }
        recentTunnels.insert(tunnelID, at: 0)
        store(Array(recentTunnels.prefix(maxNumberOfTunnels)), in: defaults)
    }

    static func handleTunnelRemoved(tunnelID: UUID, userDefaults: UserDefaults? = nil) {
        cleanupTunnels(userDefaults: userDefaults) { $0 != tunnelID }
    }

    static func cleanupTunnels(except tunnelIDsToKeep: Set<UUID>, userDefaults: UserDefaults? = nil) {
        cleanupTunnels(userDefaults: userDefaults) { tunnelIDsToKeep.contains($0) }
    }

    private static func cleanupTunnels(userDefaults: UserDefaults?, keeping shouldKeep: (UUID) -> Bool) {
        guard let defaults = resolveUserDefaults(userDefaults) else { return }
        let recentTunnels = storedIDs(in: defaults)
        let kept = recentTunnels.filter(shouldKeep)
        if kept.count != recentTunnels.count {
            store(kept, in: defaults)
        }
    }

    static func recentlyActivatedTunnelIDs(limit: Int, userDefaults: UserDefaults? = nil) -> [UUID] {
        guard let defaults = resolveUserDefaults(userDefaults) else { return [] }
        return Array(storedIDs(in: defaults).prefix(limit))
    }
}
