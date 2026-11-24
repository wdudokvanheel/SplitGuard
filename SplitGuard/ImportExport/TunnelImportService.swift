// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore

struct ImportFailure: Error, Equatable, Sendable {
    let fileName: String
    let title: String
    let message: String
}

struct ImportOutcome: Equatable, Sendable {
    let profiles: [TunnelProfile]
    let failures: [ImportFailure]
}

enum TunnelImportService {
    static func importFiles(from urls: [URL]) async -> ImportOutcome {
        guard !urls.isEmpty else {
            return ImportOutcome(profiles: [], failures: [])
        }

        return await Task.detached(priority: .userInitiated) {
            var profiles: [TunnelProfile] = []
            var failures: [ImportFailure] = []

            for url in urls {
                switch importSingleFile(at: url) {
                case .success(let profile):
                    profiles.append(profile)
                case .failure(let failure):
                    failures.append(failure)
                }
            }

            return ImportOutcome(profiles: profiles, failures: failures)
        }.value
    }

    private static func importSingleFile(at url: URL) -> Result<TunnelProfile, ImportFailure> {
        let fileName = url.lastPathComponent
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if url.pathExtension.lowercased() == "zip" {
            return .failure(ImportFailure(
                fileName: fileName,
                title: "Zip archives not supported",
                message: "Zip archives are not supported. Import .conf files instead."
            ))
        }

        let fileBaseName = url.deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileBaseName.isEmpty else {
            return .failure(ImportFailure(
                fileName: fileName,
                title: TunnelError.tunnelNameEmpty.title,
                message: TunnelError.tunnelNameEmpty.message
            ))
        }

        return readAndParseConfig(at: url, fileName: fileName, profileName: fileBaseName)
    }

    private static func readAndParseConfig(
        at url: URL,
        fileName: String,
        profileName: String
    ) -> Result<TunnelProfile, ImportFailure> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(ImportFailure(
                fileName: fileName,
                title: tr("alertCantOpenInputConfFileTitle"),
                message: error.localizedDescription
            ))
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(ImportFailure(
                fileName: fileName,
                title: tr("alertBadConfigImportTitle"),
                message: "The file is not valid UTF-8 text."
            ))
        }

        do {
            let profile = try TunnelProfileCodec.parse(text, name: profileName)
            return .success(profile)
        } catch {
            return .failure(ImportFailure(
                fileName: fileName,
                title: tr("alertBadConfigImportTitle"),
                message: error.localizedDescription
            ))
        }
    }
}
