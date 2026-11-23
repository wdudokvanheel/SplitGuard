import Foundation
import Observation

struct LogEntryItem: Identifiable, Equatable {
    let id: Int
    let timestamp: String
    let message: String

    var formattedLine: String {
        "\(timestamp) \(message)"
    }
}

@MainActor
@Observable
final class LogViewerViewModel {
    private(set) var entries: [LogEntryItem] = []
    private(set) var isLoading = true
    private(set) var isLogUnavailable = false
    var searchText = ""

    private let logFilePath: String?
    private var helper: LogViewHelper?
    private var pollingTask: Task<Void, Never>?
    private var isFetching = false

    init(logFilePath: String? = FileManager.logFileURL?.path) {
        self.logFilePath = logFilePath
        self.helper = LogViewHelper(logFilePath: logFilePath)
        if self.helper == nil {
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
        guard helper != nil, pollingTask == nil else { return }
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
        guard let helper, !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        let fetched: [LogViewHelper.LogEntry] = await withCheckedContinuation { continuation in
            helper.fetchLogEntriesSinceLastFetch { newEntries in
                continuation.resume(returning: newEntries)
            }
        }

        isLoading = false
        guard !fetched.isEmpty else { return }

        let startID = entries.count
        let newItems = fetched.enumerated().map { offset, entry in
            LogEntryItem(
                id: startID + offset,
                timestamp: entry.timestamp,
                message: entry.message
            )
        }
        entries.append(contentsOf: newItems)
    }

    func exportLogFile(completion: @escaping (Result<URL, AlertItem>) -> Void) {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        let timestamp = dateFormatter.string(from: Date())
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("splitguard-log-\(timestamp).txt")
        let fallbackText = entries.map(\.formattedLine).joined(separator: "\n")
        let filePath = logFilePath

        DispatchQueue.global(qos: .userInitiated).async {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                guard FileManager.deleteFile(at: destinationURL) else {
                    DispatchQueue.main.async {
                        completion(.failure(AlertItem(
                            title: tr("alertUnableToRemovePreviousLogTitle"),
                            message: tr("alertUnableToRemovePreviousLogMessage")
                        )))
                    }
                    return
                }
            }

            let useGlobalLogger = filePath == nil || filePath == FileManager.logFileURL?.path
            var written = false
            if useGlobalLogger {
                written = Logger.global?.writeLog(to: destinationURL.path) ?? false
            }
            if !written, let filePath, let fileLogger = try? Logger(tagged: "APP", withFilePath: filePath) {
                written = fileLogger.writeLog(to: destinationURL.path)
            }
            if !written && !fallbackText.isEmpty {
                written = (try? fallbackText.write(to: destinationURL, atomically: true, encoding: .utf8)) != nil
            }

            DispatchQueue.main.async {
                if written {
                    completion(.success(destinationURL))
                } else {
                    completion(.failure(AlertItem(
                        title: tr("alertUnableToWriteLogTitle"),
                        message: tr("alertUnableToWriteLogMessage")
                    )))
                }
            }
        }
    }
}
