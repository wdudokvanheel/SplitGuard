// SPDX-License-Identifier: MIT

import Foundation
#if canImport(WidgetKit) && os(iOS)
import WidgetKit
#endif

public enum TunnelSnapshotStatus: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case inactive
    case activating
    case active
    case deactivating
    case reasserting
    case restarting
    case waiting
}

public struct TunnelStatusSnapshot: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Hashable, Identifiable, Sendable {
        public let id: UUID
        public var name: String
        public var status: TunnelSnapshotStatus
        public var hasOnDemandRules: Bool
        public var isOnDemandEnabled: Bool
        public var updatedAt: Date

        public init(
            id: UUID,
            name: String,
            status: TunnelSnapshotStatus,
            hasOnDemandRules: Bool = false,
            isOnDemandEnabled: Bool = false,
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.status = status
            self.hasOnDemandRules = hasOnDemandRules
            self.isOnDemandEnabled = hasOnDemandRules && isOnDemandEnabled
            self.updatedAt = updatedAt
        }
    }

    public var entries: [Entry]
    public var updatedAt: Date

    public init(entries: [Entry] = [], updatedAt: Date = Date()) {
        self.entries = entries
        self.updatedAt = updatedAt
    }

    public func entry(for id: UUID) -> Entry? {
        entries.first { $0.id == id }
    }
}

public final class TunnelStatusSnapshotStore: Sendable {
    public let fileURL: URL?
    private let reloadSurfaces: Bool
    private let lock = NSLock()

    public init(fileURL: URL?, reloadSurfaces: Bool = false) {
        self.fileURL = fileURL
        self.reloadSurfaces = reloadSurfaces
    }

    public static func shared(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> TunnelStatusSnapshotStore {
        TunnelStatusSnapshotStore(
            fileURL: AppGroup.statusSnapshotURL(in: bundle, fileManager: fileManager),
            reloadSurfaces: true
        )
    }

    public func load() -> TunnelStatusSnapshot {
        guard let fileURL else { return TunnelStatusSnapshot() }
        return lock.withLock {
            readCoordinated(from: fileURL) ?? TunnelStatusSnapshot()
        }
    }

    public func replaceAll(entries: [TunnelStatusSnapshot.Entry], updatedAt: Date = Date()) {
        guard let fileURL else { return }
        let sorted = entries.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let snapshot = TunnelStatusSnapshot(entries: sorted, updatedAt: updatedAt)
        let didWrite = lock.withLock {
            writeCoordinated(snapshot, to: fileURL)
        }
        if didWrite && reloadSurfaces {
            Self.reloadSystemSurfaces()
        }
    }

    /// Updates a single tunnel's status while preserving existing app-provided metadata
    /// (such as its display name and on-demand flags) when the entry is already present.
    /// Used by the network extension, which knows the tunnel ID but not the manager name.
    public func upsertEntry(
        id: UUID,
        fallbackName: String?,
        status: TunnelSnapshotStatus,
        hasOnDemandRules: Bool? = nil,
        isOnDemandEnabled: Bool? = nil,
        updatedAt: Date = Date()
    ) {
        guard let fileURL else { return }
        let didWrite = lock.withLock { () -> Bool in
            var snapshot = readCoordinated(from: fileURL) ?? TunnelStatusSnapshot(entries: [], updatedAt: updatedAt)
            if let index = snapshot.entries.firstIndex(where: { $0.id == id }) {
                var existing = snapshot.entries[index]
                existing.status = status
                if let hasOnDemandRules {
                    existing.hasOnDemandRules = hasOnDemandRules
                }
                if let isOnDemandEnabled {
                    existing.isOnDemandEnabled = existing.hasOnDemandRules && isOnDemandEnabled
                }
                if existing.name.isEmpty, let fallbackName, !fallbackName.isEmpty {
                    existing.name = fallbackName
                }
                existing.updatedAt = updatedAt
                snapshot.entries[index] = existing
            } else if let fallbackName, !fallbackName.isEmpty {
                let rules = hasOnDemandRules ?? false
                let enabled = rules && (isOnDemandEnabled ?? false)
                snapshot.entries.append(
                    TunnelStatusSnapshot.Entry(
                        id: id,
                        name: fallbackName,
                        status: status,
                        hasOnDemandRules: rules,
                        isOnDemandEnabled: enabled,
                        updatedAt: updatedAt
                    )
                )
                snapshot.entries.sort {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            } else {
                return false
            }

            snapshot.updatedAt = updatedAt
            return writeCoordinated(snapshot, to: fileURL)
        }
        if didWrite && reloadSurfaces {
            Self.reloadSystemSurfaces()
        }
    }

    private func readCoordinated(from url: URL) -> TunnelStatusSnapshot? {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var decoded: TunnelStatusSnapshot?

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            guard let data = try? Data(contentsOf: coordinatedURL) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            decoded = try? decoder.decode(TunnelStatusSnapshot.self, from: data)
        }

        if let coordinationError {
            Log.debug("Status snapshot read coordination failed: \(coordinationError.localizedDescription)")
        }
        return decoded
    }

    private func writeCoordinated(_ snapshot: TunnelStatusSnapshot, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        guard let data = try? encoder.encode(snapshot) else {
            return false
        }

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var wroteSuccessfully = false

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
                wroteSuccessfully = true
            } catch {
                Log.error("Failed to write status snapshot: \(error.localizedDescription)")
            }
        }

        if let coordinationError {
            Log.error("Status snapshot write coordination failed: \(coordinationError.localizedDescription)")
        }
        return wroteSuccessfully
    }

    private static func reloadSystemSurfaces() {
        #if canImport(WidgetKit) && os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadAllControls()
        }
        #endif
    }
}
