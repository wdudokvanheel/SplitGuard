// SPDX-License-Identifier: MIT

import Foundation
import enum SplitGuardCore.AppGroup
import enum SplitGuardCore.Log

enum RecentTunnelsTracker {
    private static let keyRecentlyActivatedTunnelNames = "recentlyActivatedTunnelNames"
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

    static func handleTunnelActivated(tunnelName: String, userDefaults: UserDefaults? = nil) {
        guard let defaults = resolveUserDefaults(userDefaults) else { return }
        var recentTunnels = defaults.stringArray(forKey: keyRecentlyActivatedTunnelNames) ?? []
        if let existingIndex = recentTunnels.firstIndex(of: tunnelName) {
            recentTunnels.remove(at: existingIndex)
        }
        recentTunnels.insert(tunnelName, at: 0)
        if recentTunnels.count > maxNumberOfTunnels {
            recentTunnels.removeLast(recentTunnels.count - maxNumberOfTunnels)
        }
        defaults.set(recentTunnels, forKey: keyRecentlyActivatedTunnelNames)
    }

    static func handleTunnelRemoved(tunnelName: String, userDefaults: UserDefaults? = nil) {
        guard let defaults = resolveUserDefaults(userDefaults) else { return }
        var recentTunnels = defaults.stringArray(forKey: keyRecentlyActivatedTunnelNames) ?? []
        if let existingIndex = recentTunnels.firstIndex(of: tunnelName) {
            recentTunnels.remove(at: existingIndex)
            defaults.set(recentTunnels, forKey: keyRecentlyActivatedTunnelNames)
        }
    }

    static func handleTunnelRenamed(oldName: String, newName: String, userDefaults: UserDefaults? = nil) {
        guard let defaults = resolveUserDefaults(userDefaults) else { return }
        var recentTunnels = defaults.stringArray(forKey: keyRecentlyActivatedTunnelNames) ?? []
        if let existingIndex = recentTunnels.firstIndex(of: oldName) {
            recentTunnels[existingIndex] = newName
            defaults.set(recentTunnels, forKey: keyRecentlyActivatedTunnelNames)
        }
    }

    static func cleanupTunnels(except tunnelNamesToKeep: Set<String>, userDefaults: UserDefaults? = nil) {
        guard let defaults = resolveUserDefaults(userDefaults) else { return }
        var recentTunnels = defaults.stringArray(forKey: keyRecentlyActivatedTunnelNames) ?? []
        let oldCount = recentTunnels.count
        recentTunnels.removeAll { !tunnelNamesToKeep.contains($0) }
        if oldCount != recentTunnels.count {
            defaults.set(recentTunnels, forKey: keyRecentlyActivatedTunnelNames)
        }
    }

    static func recentlyActivatedTunnelNames(limit: Int, userDefaults: UserDefaults? = nil) -> [String] {
        guard let defaults = resolveUserDefaults(userDefaults) else { return [] }
        var recentTunnels = defaults.stringArray(forKey: keyRecentlyActivatedTunnelNames) ?? []
        if limit < recentTunnels.count {
            recentTunnels.removeLast(recentTunnels.count - limit)
        }
        return recentTunnels
    }
}
