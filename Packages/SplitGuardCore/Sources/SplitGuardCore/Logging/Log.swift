// SPDX-License-Identifier: MIT

import Foundation
import os

public enum Log {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var source = "APP"
        private var logger = os.Logger(subsystem: "com.bitechular.splitguard", category: "APP")
        private var logFile: LogFile?
        private var configuredURL: URL?

        func configure(
            source: String,
            fileURL: URL?,
            subsystem: String,
            category: String?,
            maxBytes: Int
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }

            let resolvedCategory = category ?? source
            let isSameConfiguration = self.source == source && self.configuredURL == fileURL && self.logFile != nil
            self.source = source
            self.logger = os.Logger(subsystem: subsystem, category: resolvedCategory)

            if isSameConfiguration {
                return false
            }

            self.configuredURL = fileURL
            self.logFile = fileURL.map { LogFile(url: $0, maxBytes: maxBytes) }
            return true
        }

        func write(level: LogLevel, message: String) {
            lock.lock()
            let currentSource = source
            let currentLogger = logger
            let currentFile = logFile
            lock.unlock()

            switch level {
            case .debug:
                currentLogger.debug("\(message, privacy: .public)")
            case .info:
                currentLogger.info("\(message, privacy: .public)")
            case .warning:
                currentLogger.warning("\(message, privacy: .public)")
            case .error:
                currentLogger.error("\(message, privacy: .public)")
            }

            currentFile?.append(source: currentSource, level: level, message: message)
        }

        func flush() {
            lock.lock()
            let currentFile = logFile
            lock.unlock()
            currentFile?.flush()
        }
    }

    private static let state = State()

    public static func configure(
        source: String,
        fileURL: URL?,
        subsystem: String = "com.bitechular.splitguard",
        category: String? = nil,
        maxBytes: Int = LogFile.defaultMaxBytes
    ) {
        let didConfigure = state.configure(
            source: source,
            fileURL: fileURL,
            subsystem: subsystem,
            category: category,
            maxBytes: maxBytes
        )
        guard didConfigure else { return }

        if fileURL == nil {
            error("Unable to determine log destination path. Log will not be saved to file.")
        }

        var appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown version"
        if let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            appVersion += " (\(appBuild))"
        }
        info("App version: \(appVersion)")
    }

    public static func debug(_ message: String) {
        state.write(level: .debug, message: message)
    }

    public static func info(_ message: String) {
        state.write(level: .info, message: message)
    }

    public static func warning(_ message: String) {
        state.write(level: .warning, message: message)
    }

    public static func error(_ message: String) {
        state.write(level: .error, message: message)
    }

    public static func log(_ level: LogLevel, _ message: String) {
        state.write(level: level, message: message)
    }

    public static func flush() {
        state.flush()
    }
}
