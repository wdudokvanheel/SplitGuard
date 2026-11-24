// SPDX-License-Identifier: MIT

import Darwin
import Foundation

public enum LogLevel: String, Codable, Equatable, Hashable, Sendable {
    case debug
    case info
    case warning
    case error

    public var label: String {
        rawValue.uppercased()
    }

    init?(label: Substring) {
        switch label.uppercased() {
        case "DEBUG":
            self = .debug
        case "INFO":
            self = .info
        case "WARNING", "WARN":
            self = .warning
        case "ERROR":
            self = .error
        default:
            return nil
        }
    }
}

public struct LogEntry: Equatable, Sendable {
    public let timestamp: Date
    public let timestampText: String
    public let source: String
    public let level: LogLevel
    public let message: String
    public let formattedLine: String

    public init(
        timestamp: Date,
        timestampText: String,
        source: String,
        level: LogLevel,
        message: String,
        formattedLine: String
    ) {
        self.timestamp = timestamp
        self.timestampText = timestampText
        self.source = source
        self.level = level
        self.message = message
        self.formattedLine = formattedLine
    }

    public static func make(
        timestamp: Date,
        source: String,
        level: LogLevel,
        message: String
    ) -> LogEntry {
        let timestampText = LogTimestampCodec.format(timestamp)
        let sanitizedSource = sanitizeSource(source)
        let sanitizedMessage = sanitizeMessage(message)
        let line = "\(timestampText) [\(sanitizedSource)] [\(level.label)] \(sanitizedMessage)"
        return LogEntry(
            timestamp: LogTimestampCodec.parse(timestampText) ?? timestamp,
            timestampText: timestampText,
            source: sanitizedSource,
            level: level,
            message: sanitizedMessage,
            formattedLine: line
        )
    }

    public static func parse(line: String, fallbackTimestamp: Date = Date(timeIntervalSince1970: 0)) -> LogEntry? {
        let trimmedLine = line.trimmingCharacters(in: CharacterSet.newlines)
        guard !trimmedLine.isEmpty else { return nil }

        let sub = trimmedLine[...]
        guard let firstSpace = sub.firstIndex(of: " ") else {
            return fallbackEntry(line: trimmedLine, timestamp: fallbackTimestamp)
        }
        let timestampPart = sub[..<firstSpace]
        guard let parsedDate = LogTimestampCodec.parse(timestampPart) else {
            return fallbackEntry(line: trimmedLine, timestamp: fallbackTimestamp)
        }

        let afterTimestamp = sub[sub.index(after: firstSpace)...]
        guard afterTimestamp.first == "[",
              let sourceClose = afterTimestamp.firstIndex(of: "]")
        else {
            return fallbackEntry(line: trimmedLine, timestamp: parsedDate, timestampText: String(timestampPart))
        }
        let sourceStart = afterTimestamp.index(after: afterTimestamp.startIndex)
        let source = String(afterTimestamp[sourceStart..<sourceClose])

        let afterSource = afterTimestamp[afterTimestamp.index(after: sourceClose)...]
        guard afterSource.hasPrefix(" ["),
              let levelOpen = afterSource.firstIndex(of: "["),
              let levelClose = afterSource[levelOpen...].firstIndex(of: "]")
        else {
            return fallbackEntry(line: trimmedLine, timestamp: parsedDate, timestampText: String(timestampPart))
        }
        let levelStart = afterSource.index(after: levelOpen)
        guard let level = LogLevel(label: afterSource[levelStart..<levelClose]) else {
            return fallbackEntry(line: trimmedLine, timestamp: parsedDate, timestampText: String(timestampPart))
        }

        let afterLevel = afterSource[afterSource.index(after: levelClose)...]
        let message: String
        if afterLevel.first == " " {
            message = String(afterLevel.dropFirst())
        } else {
            message = String(afterLevel)
        }

        return LogEntry(
            timestamp: parsedDate,
            timestampText: String(timestampPart),
            source: source,
            level: level,
            message: message,
            formattedLine: trimmedLine
        )
    }

    static func sanitizeSource(_ source: String) -> String {
        let normalized = sanitizeMessage(source)
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespaces)
        return normalized.isEmpty ? "LOG" : normalized
    }

    static func sanitizeMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .newlines)
        guard trimmed.contains("\n") || trimmed.contains("\r") else {
            return trimmed
        }
        var output = ""
        output.reserveCapacity(trimmed.count)
        var previousWasNewline = false
        for character in trimmed {
            if character == "\n" || character == "\r" || character == "\r\n" {
                if !previousWasNewline {
                    output.append(" ")
                    previousWasNewline = true
                }
            } else {
                output.append(character)
                previousWasNewline = false
            }
        }
        return output
    }

    private static func fallbackEntry(
        line: String,
        timestamp: Date,
        timestampText: String? = nil
    ) -> LogEntry {
        let text = timestampText ?? LogTimestampCodec.format(timestamp)
        return LogEntry(
            timestamp: timestamp,
            timestampText: text,
            source: "LOG",
            level: .info,
            message: line,
            formattedLine: line
        )
    }
}

enum LogTimestampCodec {
    static func format(_ date: Date) -> String {
        let totalMilliseconds = Int64((date.timeIntervalSince1970 * 1000.0).rounded(.down))
        let wholeSeconds: Int64
        if totalMilliseconds >= 0 {
            wholeSeconds = totalMilliseconds / 1000
        } else {
            wholeSeconds = (totalMilliseconds - 999) / 1000
        }
        let milliseconds = Int(totalMilliseconds - wholeSeconds * 1000)

        var seconds = time_t(wholeSeconds)
        var calendarTime = tm()
        gmtime_r(&seconds, &calendarTime)

        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            calendarTime.tm_year + 1900,
            calendarTime.tm_mon + 1,
            calendarTime.tm_mday,
            calendarTime.tm_hour,
            calendarTime.tm_min,
            calendarTime.tm_sec,
            milliseconds
        )
    }

    static func parse(_ text: some StringProtocol) -> Date? {
        let utf8 = Array(text.utf8)
        // Exact format: YYYY-MM-DDTHH:MM:SS.SSSZ (24 ASCII bytes)
        guard utf8.count == 24,
              utf8[4] == 45,  // '-'
              utf8[7] == 45,  // '-'
              utf8[10] == 84, // 'T'
              utf8[13] == 58, // ':'
              utf8[16] == 58, // ':'
              utf8[19] == 46, // '.'
              utf8[23] == 90  // 'Z'
        else {
            return nil
        }

        guard let year = parseDigits(utf8, offset: 0, count: 4),
              let month = parseDigits(utf8, offset: 5, count: 2),
              let day = parseDigits(utf8, offset: 8, count: 2),
              let hour = parseDigits(utf8, offset: 11, count: 2),
              let minute = parseDigits(utf8, offset: 14, count: 2),
              let second = parseDigits(utf8, offset: 17, count: 2),
              let millisecond = parseDigits(utf8, offset: 20, count: 3),
              (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...60).contains(second)
        else {
            return nil
        }

        var calendarTime = tm()
        calendarTime.tm_year = Int32(year - 1900)
        calendarTime.tm_mon = Int32(month - 1)
        calendarTime.tm_mday = Int32(day)
        calendarTime.tm_hour = Int32(hour)
        calendarTime.tm_min = Int32(minute)
        calendarTime.tm_sec = Int32(second)

        let seconds = timegm(&calendarTime)
        return Date(timeIntervalSince1970: Double(seconds) + Double(millisecond) / 1000.0)
    }

    private static func parseDigits(_ bytes: [UInt8], offset: Int, count: Int) -> Int? {
        var result = 0
        for index in offset..<(offset + count) {
            let byte = bytes[index]
            guard byte >= 48 && byte <= 57 else { return nil }
            result = result * 10 + Int(byte - 48)
        }
        return result
    }
}

public final class LogFile: @unchecked Sendable {
    public static let defaultMaxBytes = 512 * 1024

    public let url: URL
    public let backupURL: URL
    public let maxBytes: Int

    private let queue: DispatchQueue

    public init(url: URL, maxBytes: Int = LogFile.defaultMaxBytes) {
        self.url = url
        self.backupURL = Self.backupURL(for: url)
        self.maxBytes = max(1, maxBytes)
        self.queue = DispatchQueue(label: "com.bitechular.splitguard.logfile.\(url.lastPathComponent)", qos: .utility)
    }

    public static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("1")
    }

    public func append(source: String, level: LogLevel, message: String, timestamp: Date = Date()) {
        let entry = LogEntry.make(timestamp: timestamp, source: source, level: level, message: message)
        let lineData = Data((entry.formattedLine + "\n").utf8)
        queue.async { [url, backupURL, maxBytes] in
            Self.writeLine(lineData, to: url, backupURL: backupURL, maxBytes: maxBytes)
        }
    }

    public func flush() {
        queue.sync {}
    }

    private static func writeLine(_ data: Data, to url: URL, backupURL: URL, maxBytes: Int) {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let currentSize = fileSize(atPath: url.path)
        if currentSize > 0 && currentSize + UInt64(data.count) > UInt64(maxBytes) {
            rotate(fileURL: url, backupURL: backupURL, fileManager: fileManager)
        }

        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }

        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < rawBuffer.count {
                let written = Darwin.write(
                    fd,
                    baseAddress.advanced(by: totalWritten),
                    rawBuffer.count - totalWritten
                )
                if written <= 0 {
                    if written < 0 && errno == EINTR {
                        continue
                    }
                    break
                }
                totalWritten += written
            }
        }
    }

    private static func rotate(fileURL: URL, backupURL: URL, fileManager: FileManager) {
        if fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.removeItem(at: backupURL)
        }
        try? fileManager.moveItem(at: fileURL, to: backupURL)
    }

    private static func fileSize(atPath path: String) -> UInt64 {
        var info = stat()
        guard stat(path, &info) == 0 else { return 0 }
        return UInt64(max(0, info.st_size))
    }
}

public final class MergedLogReader: @unchecked Sendable {
    private struct FileFingerprint: Equatable {
        let inode: UInt64
        let size: UInt64
        let mtimeSeconds: Int
        let mtimeNanoseconds: Int
    }

    private struct TrackedFileState {
        let url: URL
        let order: Int
        var fingerprint: FileFingerprint?
        var parsedOffset: UInt64 = 0
        var partialLineBuffer = Data()
        var entries: [LogEntry] = []
    }

    public let logURLs: [URL]

    private let lock = NSLock()
    private var trackedFiles: [TrackedFileState]
    private var cachedMergedEntries: [LogEntry] = []
    private var hasLoadedOnce = false

    public convenience init(directoryURL: URL) {
        self.init(logURLs: AppGroup.logFileURLs(inDirectory: directoryURL))
    }

    public init(logURLs: [URL]) {
        self.logURLs = logURLs
        var states: [TrackedFileState] = []
        states.reserveCapacity(logURLs.count * 2)
        var order = 0
        for logURL in logURLs {
            states.append(TrackedFileState(url: LogFile.backupURL(for: logURL), order: order))
            order += 1
            states.append(TrackedFileState(url: logURL, order: order))
            order += 1
        }
        self.trackedFiles = states
    }

    public func readAll() -> [LogEntry] {
        poll().entries
    }

    public func poll() -> (entries: [LogEntry], didChange: Bool) {
        lock.lock()
        defer { lock.unlock() }

        var anyChanged = false
        for index in trackedFiles.indices {
            if refresh(&trackedFiles[index]) {
                anyChanged = true
            }
        }

        if anyChanged || !hasLoadedOnce {
            hasLoadedOnce = true
            cachedMergedEntries = mergeEntries()
        }
        return (cachedMergedEntries, anyChanged)
    }

    public func exportText() -> String {
        let entries = readAll()
        guard !entries.isEmpty else { return "" }
        return entries.map(\.formattedLine).joined(separator: "\n") + "\n"
    }

    public func writeExport(to destinationURL: URL) throws {
        let text = exportText()
        try text.write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    private func refresh(_ state: inout TrackedFileState) -> Bool {
        guard let currentFingerprint = Self.fingerprint(atPath: state.url.path) else {
            guard state.fingerprint != nil || !state.entries.isEmpty else {
                return false
            }
            state.fingerprint = nil
            state.parsedOffset = 0
            state.partialLineBuffer.removeAll(keepingCapacity: false)
            state.entries.removeAll(keepingCapacity: false)
            return true
        }

        if state.fingerprint == currentFingerprint {
            return false
        }

        if let previous = state.fingerprint,
           previous.inode == currentFingerprint.inode,
           currentFingerprint.size > previous.size {
            let deltaLength = Int(currentFingerprint.size - state.parsedOffset)
            if let chunk = Self.readBytes(atPath: state.url.path, offset: state.parsedOffset, length: deltaLength) {
                state.fingerprint = currentFingerprint
                state.parsedOffset += UInt64(chunk.count)
                appendChunk(chunk, to: &state)
                return true
            }
        }

        // File is new, rotated (inode changed), truncated, or modified in place: read from offset 0.
        state.fingerprint = currentFingerprint
        state.parsedOffset = 0
        state.partialLineBuffer.removeAll(keepingCapacity: false)
        state.entries.removeAll(keepingCapacity: false)

        if currentFingerprint.size > 0,
           let chunk = Self.readBytes(atPath: state.url.path, offset: 0, length: Int(currentFingerprint.size)) {
            state.parsedOffset = UInt64(chunk.count)
            appendChunk(chunk, to: &state)
        }
        return true
    }

    private func appendChunk(_ chunk: Data, to state: inout TrackedFileState) {
        guard !chunk.isEmpty else { return }
        var combined = Data()
        if !state.partialLineBuffer.isEmpty {
            combined.append(state.partialLineBuffer)
            state.partialLineBuffer.removeAll(keepingCapacity: true)
        }
        combined.append(chunk)

        let newlineByte: UInt8 = 10
        var cursor = combined.startIndex
        while let newlineIndex = combined[cursor...].firstIndex(of: newlineByte) {
            let lineData = combined[cursor..<newlineIndex]
            let lineString = String(decoding: lineData, as: UTF8.self)
            let fallbackTimestamp = state.entries.last?.timestamp ?? Date(timeIntervalSince1970: 0)
            if let entry = LogEntry.parse(line: lineString, fallbackTimestamp: fallbackTimestamp) {
                state.entries.append(entry)
            }
            cursor = combined.index(after: newlineIndex)
        }

        if cursor < combined.endIndex {
            state.partialLineBuffer = Data(combined[cursor...])
        }
    }

    private func mergeEntries() -> [LogEntry] {
        var indexed: [(entry: LogEntry, fileOrder: Int, lineIndex: Int)] = []
        let totalCount = trackedFiles.reduce(0) { $0 + $1.entries.count }
        indexed.reserveCapacity(totalCount)

        for state in trackedFiles {
            for (lineIndex, entry) in state.entries.enumerated() {
                indexed.append((entry: entry, fileOrder: state.order, lineIndex: lineIndex))
            }
        }

        indexed.sort { lhs, rhs in
            if lhs.entry.timestamp != rhs.entry.timestamp {
                return lhs.entry.timestamp < rhs.entry.timestamp
            }
            if lhs.fileOrder != rhs.fileOrder {
                return lhs.fileOrder < rhs.fileOrder
            }
            return lhs.lineIndex < rhs.lineIndex
        }
        return indexed.map(\.entry)
    }

    private static func fingerprint(atPath path: String) -> FileFingerprint? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileFingerprint(
            inode: UInt64(info.st_ino),
            size: UInt64(max(0, info.st_size)),
            mtimeSeconds: info.st_mtimespec.tv_sec,
            mtimeNanoseconds: info.st_mtimespec.tv_nsec
        )
    }

    private static func readBytes(atPath path: String, offset: UInt64, length: Int) -> Data? {
        guard length > 0 else { return Data() }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        if offset > 0 {
            let seeked = lseek(fd, off_t(offset), SEEK_SET)
            guard seeked >= 0 else { return nil }
        }

        var buffer = [UInt8](repeating: 0, count: length)
        var totalRead = 0
        while totalRead < length {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: totalRead), length - totalRead)
            }
            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                return nil
            }
            if bytesRead == 0 {
                break
            }
            totalRead += bytesRead
        }
        return Data(buffer.prefix(totalRead))
    }
}
