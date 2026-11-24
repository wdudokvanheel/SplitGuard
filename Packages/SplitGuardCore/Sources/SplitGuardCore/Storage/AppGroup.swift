// SPDX-License-Identifier: MIT

import Foundation

public enum AppGroup {
    public static let infoDictionaryKey = "SplitGuardAppGroupID"
    public static let legacyInfoDictionaryKey = "com.wireguard.ios.app_group_id"
    public static let appLogFilename = "app.log"
    public static let tunnelLogFilename = "tunnel.log"

    public static func identifier(in bundle: Bundle = .main) -> String? {
        if let value = bundle.object(forInfoDictionaryKey: infoDictionaryKey) as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let legacy = bundle.object(forInfoDictionaryKey: legacyInfoDictionaryKey) as? String {
            let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    public static func containerURL(
        in bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let groupID = identifier(in: bundle) else {
            return nil
        }
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    public static func appLogURL(
        in bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        containerURL(in: bundle, fileManager: fileManager).map(appLogURL(inDirectory:))
    }

    public static func tunnelLogURL(
        in bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        containerURL(in: bundle, fileManager: fileManager).map(tunnelLogURL(inDirectory:))
    }

    public static func appLogURL(inDirectory directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(appLogFilename, isDirectory: false)
    }

    public static func tunnelLogURL(inDirectory directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(tunnelLogFilename, isDirectory: false)
    }

    public static func logFileURLs(inDirectory directoryURL: URL) -> [URL] {
        [
            appLogURL(inDirectory: directoryURL),
            tunnelLogURL(inDirectory: directoryURL)
        ]
    }
}
