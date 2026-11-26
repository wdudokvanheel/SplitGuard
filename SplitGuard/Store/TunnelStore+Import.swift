// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore

extension TunnelStore {
    func importFiles(from urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard hasLoaded else {
            pendingOpenedURLs.append(contentsOf: urls)
            return
        }

        let outcome = await TunnelImportService.importFiles(from: urls)
        var failures = outcome.failures
        var addedTunnels: [Tunnel] = []

        if !outcome.profiles.isEmpty {
            let previouslyActiveTunnel = tunnels.first { $0.status == .active || $0.status == .activating }
            await backend.setConfigurationChangeObservationPaused(true)

            for profile in outcome.profiles {
                let result = await saveImportedProfile(profile)
                switch result {
                case .success(let created):
                    addedTunnels.append(created)
                case .failure(let failure):
                    failures.append(failure)
                }
            }

            await backend.setConfigurationChangeObservationPaused(false)

            if !addedTunnels.isEmpty {
                sortTunnels()
                bumpRevision()
                updateQuickActions()

                if backend.saveNewDeactivatesActiveTunnel, let activeTunnel = previouslyActiveTunnel {
                    await recoverActiveTunnelAfterAdd(activeTunnel)
                }
            }
        }

        presentImportFailures(failures, importedCount: addedTunnels.count, totalCount: urls.count)
    }

    func importFromOpenedURL(_ url: URL) async {
        guard hasLoaded else {
            pendingOpenedURLs.append(url)
            return
        }

        let isInboxFile = url.pathComponents.contains("Inbox")
        await importFiles(from: [url])
        if isInboxFile {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func flushPendingOpenedURLs() async {
        guard hasLoaded, !pendingOpenedURLs.isEmpty else { return }
        let urls = pendingOpenedURLs
        pendingOpenedURLs.removeAll()
        for url in urls {
            await importFromOpenedURL(url)
        }
    }

    @discardableResult
    func addProfile(_ profile: TunnelProfile, named rawName: String) async -> Bool {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            present(error: .tunnelNameEmpty)
            return false
        }

        var normalizedProfile = profile
        normalizedProfile.name = trimmedName
        normalizedProfile.options = normalizedProfile.options.sanitized(for: normalizedProfile)

        do {
            _ = try await addTunnel(normalizedProfile)
            return true
        } catch {
            present(error: wrapError(error, fallback: TunnelError.saveFailed))
            return false
        }
    }

    @discardableResult
    func importConfigText(_ text: String, named rawName: String) async -> Bool {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            present(error: .tunnelNameEmpty)
            return false
        }

        do {
            let profile = try TunnelProfileCodec.parse(text, name: trimmedName)
            return await addProfile(profile, named: trimmedName)
        } catch {
            presentAlert(
                title: L10n.tr("alert.import.badConfig.title", defaultValue: "Unable to import tunnel"),
                message: error.localizedDescription
            )
            return false
        }
    }

    func exportAllTunnelsZip() async throws -> URL {
        try await TunnelExportService.export(profiles: tunnels.map(\.profile))
    }

    func presentImportFailures(_ failures: [ImportFailure], importedCount: Int, totalCount: Int) {
        guard !failures.isEmpty else { return }

        if failures.count == 1 && totalCount == 1 {
            presentAlert(title: failures[0].title, message: failures[0].message)
            return
        }

        let title: String
        if importedCount > 0 {
            title = L10n.tr(
                "alert.import.partial.title",
                defaultValue: "Imported \(importedCount) of \(totalCount) tunnels"
            )
        } else {
            title = failures.count == 1
                ? failures[0].title
                : L10n.tr("alert.import.multipleFailed.title", defaultValue: "Unable to import tunnels")
        }

        let message = failures
            .map { "\($0.fileName): \($0.message)" }
            .joined(separator: "\n")
        presentAlert(title: title, message: message)
    }
}

private extension TunnelStore {
    func saveImportedProfile(_ profile: TunnelProfile) async -> Result<Tunnel, ImportFailure> {
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayFileName = trimmedName.isEmpty ? "tunnel.conf" : "\(trimmedName).conf"

        guard !trimmedName.isEmpty else {
            return .failure(ImportFailure(
                fileName: displayFileName,
                title: TunnelError.tunnelNameEmpty.title,
                message: TunnelError.tunnelNameEmpty.message
            ))
        }

        if tunnels.contains(where: { $0.name == trimmedName }) {
            let error = TunnelError.tunnelNameAlreadyExists(trimmedName)
            return .failure(ImportFailure(
                fileName: displayFileName,
                title: error.title,
                message: error.message
            ))
        }

        var normalizedProfile = profile
        normalizedProfile.name = trimmedName
        normalizedProfile.options = normalizedProfile.options.sanitized(for: normalizedProfile)

        markLocalMutation()
        do {
            let record = try await backend.save(
                normalizedProfile,
                onDemandPolicy: .off,
                isOnDemandEnabled: false,
                replacing: nil
            )
            markLocalMutation()
            let created = upsertTunnel(from: record)
            return .success(created)
        } catch {
            let tunnelError = wrapError(error, fallback: TunnelError.saveFailed)
            return .failure(ImportFailure(
                fileName: displayFileName,
                title: tunnelError.title,
                message: tunnelError.message
            ))
        }
    }
}
