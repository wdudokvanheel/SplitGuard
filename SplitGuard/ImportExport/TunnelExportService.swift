// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore

enum TunnelExportService {
    static func export(profiles: [TunnelProfile], to destinationURL: URL? = nil) async throws -> URL {
        guard !profiles.isEmpty else {
            throw TunnelError.noTunnelsToExport
        }

        let targetURL = destinationURL ?? makeDefaultDestinationURL()

        return try await Task.detached(priority: .userInitiated) {
            do {
                try ProfileArchiveExporter.export(profiles: profiles, to: targetURL)
                return targetURL
            } catch ProfileArchiveExporterError.noProfiles {
                throw TunnelError.noTunnelsToExport
            } catch {
                throw TunnelError.exportFailed(error.localizedDescription)
            }
        }.value
    }

    private static func makeDefaultDestinationURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("splitguard-tunnels-\(UUID().uuidString.prefix(8)).zip")
    }
}
