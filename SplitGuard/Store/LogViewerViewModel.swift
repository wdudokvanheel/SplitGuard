import Foundation
import Observation
import enum SplitGuardCore.AppGroup
import enum SplitGuardCore.Log
import struct SplitGuardCore.LogEntry
import class SplitGuardCore.MergedLogReader

struct LogEntryItem: Identifiable, Equatable {
    let id: Int
    let timestamp: String
    let message: String
    let formattedLine: String

    init(id: Int, entry: LogEntry) {
        self.id = id
        self.timestamp = entry.timestampText
        self.message = "[\(entry.source)] [\(entry.level.label)] \(entry.message)"
        self.formattedLine = entry.formattedLine
    }
}

@MainActor
@Observable
final class LogViewerViewModel {
    private(set) var entries: [LogEntryItem] = []
    private(set) var isLoading = true
    private(set) var isLogUnavailable = false
    var searchText = ""

    private let reader: MergedLogReader?
    private var pollingTask: Task<Void, Never>?
    private var isFetching = false

    init(logDirectoryURL: URL? = AppGroup.containerURL()) {
        if let logDirectoryURL {
            self.reader = MergedLogReader(directoryURL: logDirectoryURL)
        } else {
            self.reader = nil
            self.isLoading = false
            self.isLogUnavailable = true
        }
    }

    var filteredEntries: [LogEntryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            entry.message.localizedCaseInsensitiveContains(query) ||
                entry.timestamp.localizedCaseInsensitiveContains(query)
        }
    }

    func startPolling() {
        guard reader != nil, pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetchOnce()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func fetchOnce() async {
        guard let reader, !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        let result = await Task.detached(priority: .userInitiated) {
            Log.flush()
            return reader.poll()
        }.value

        isLoading = false
        guard result.didChange || entries.count != result.entries.count else { return }

        entries = result.entries.enumerated().map { offset, entry in
            LogEntryItem(id: offset, entry: entry)
        }
    }

    func exportLogFile(completion: @escaping (Result<URL, AlertItem>) -> Void) {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        let timestamp = dateFormatter.string(from: Date())
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("splitguard-log-\(timestamp).txt")
        let fallbackText = entries.map(\.formattedLine).joined(separator: "\n")
        let reader = self.reader

        DispatchQueue.global(qos: .userInitiated).async {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                do {
                    try FileManager.default.removeItem(at: destinationURL)
                } catch {
                    DispatchQueue.main.async {
                        completion(.failure(AlertItem(
                            title: L10n.tr("alert.log.exportFailed.title", defaultValue: "Log export failed"),
                            message: L10n.tr(
                                "alert.log.removePreviousFailed.message",
                                defaultValue: "The pre-existing log could not be cleared"
                            )
                        )))
                    }
                    return
                }
            }

            Log.flush()
            var written = false
            if let reader {
                written = (try? reader.writeExport(to: destinationURL)) != nil
            }
            if !written && !fallbackText.isEmpty {
                written = (try? fallbackText.write(to: destinationURL, atomically: true, encoding: .utf8)) != nil
            }

            DispatchQueue.main.async {
                if written {
                    completion(.success(destinationURL))
                } else {
                    completion(.failure(AlertItem(
                        title: L10n.tr("alert.log.exportFailed.title", defaultValue: "Log export failed"),
                        message: L10n.tr(
                            "alert.log.writeFailed.message",
                            defaultValue: "Unable to write logs to file"
                        )
                    )))
                }
            }
        }
    }
}
