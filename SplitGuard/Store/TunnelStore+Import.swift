import Foundation
import WireGuardKit

extension TunnelStore {
    func importFiles(from urls: [URL], completion: (() -> Void)? = nil) {
        guard !urls.isEmpty else {
            completion?()
            return
        }
        guard let manager else {
            pendingOpenedURLs.append(contentsOf: urls)
            completion?()
            return
        }

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplitGuardImport-\(UUID().uuidString)", isDirectory: true)
        let stagedResult = stageImportFiles(urls, into: stagingDirectory)
        guard !stagedResult.stagedURLs.isEmpty else {
            _ = FileManager.deleteFile(at: stagingDirectory)
            if let message = stagedResult.errorMessage {
                presentAlert(title: tr("alertCantOpenInputConfFileTitle"), message: message)
            }
            completion?()
            return
        }

        TunnelImporter.importFromFile(
            urls: stagedResult.stagedURLs,
            into: manager,
            sourceVC: self,
            errorPresenterType: SwiftUIErrorPresenter.self
        ) { [weak self] in
            DispatchQueue.main.async {
                _ = FileManager.deleteFile(at: stagingDirectory)
                self?.syncTunnelsFromManager()
                completion?()
            }
        }
    }

    func importFromOpenedURL(_ url: URL) {
        guard manager != nil else {
            pendingOpenedURLs.append(url)
            return
        }
        let isInboxFile = url.pathComponents.contains("Inbox")
        importFiles(from: [url]) {
            if isInboxFile {
                _ = FileManager.deleteFile(at: url)
            }
        }
    }

    func addConfiguration(
        _ configuration: TunnelConfiguration,
        splitDNSConfiguration: SplitDNSConfiguration = .allDomains,
        named rawName: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let manager else {
            presentAlert(title: "Not Ready", message: "Tunnel manager is still loading.")
            completion?(false)
            return
        }
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            present(error: TunnelsManagerError.tunnelNameEmpty)
            completion?(false)
            return
        }

        configuration.name = trimmedName
        manager.add(
            tunnelConfiguration: configuration,
            splitDNSConfiguration: splitDNSConfiguration
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.syncTunnelsFromManager()
                    completion?(true)
                case .failure(let error):
                    self.present(error: error)
                    completion?(false)
                }
            }
        }
    }

    func importConfigText(
        _ text: String,
        named rawName: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            present(error: TunnelsManagerError.tunnelNameEmpty)
            completion?(false)
            return
        }

        do {
            let splitDNS = SplitDNSConfigCodec.extract(from: text)
            let configuration = try TunnelConfiguration(fromWgQuickConfig: text, called: trimmedName)
            addConfiguration(
                configuration,
                splitDNSConfiguration: splitDNS,
                named: trimmedName,
                completion: completion
            )
        } catch let appError as WireGuardAppError {
            present(error: appError)
            completion?(false)
        } catch {
            presentAlert(title: tr("alertBadConfigImportTitle"), message: String(describing: error))
            completion?(false)
        }
    }

    func flushPendingOpenedURLs() {
        guard !pendingOpenedURLs.isEmpty else { return }
        let urls = pendingOpenedURLs
        pendingOpenedURLs.removeAll()
        for url in urls {
            importFromOpenedURL(url)
        }
    }

    private func stageImportFiles(
        _ urls: [URL],
        into directory: URL
    ) -> (stagedURLs: [URL], errorMessage: String?) {
        var stagedURLs: [URL] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let destination = directory.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
                stagedURLs.append(destination)
            }
            return (stagedURLs, nil)
        } catch {
            return (stagedURLs, error.localizedDescription)
        }
    }
}
