// SPDX-License-Identifier: MIT

import Foundation

public enum ProfileArchiveExporterError: Error, Equatable, LocalizedError, Sendable {
    case noProfiles
    case coordinationFailed(String)
    case copyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noProfiles:
            return "There are no tunnel profiles to export."
        case .coordinationFailed(let detail):
            return "Unable to build zip archive: \(detail)"
        case .copyFailed(let detail):
            return "Unable to write zip archive: \(detail)"
        }
    }
}

public enum ProfileArchiveExporter {
    private static let archiveFolderName = "splitguard-tunnels"

    public static func export(profiles: [TunnelProfile], to destinationURL: URL) throws {
        guard !profiles.isEmpty else {
            throw ProfileArchiveExporterError.noProfiles
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("SplitGuardExport-\(UUID().uuidString)", isDirectory: true)
        let stagingFolder = tempRoot.appendingPathComponent(archiveFolderName, isDirectory: true)

        try fileManager.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempRoot)
        }

        var usedLowercasedNames = Set<String>()
        for profile in profiles {
            let fileName = uniqueFileName(for: profile.name, usedLowercasedNames: &usedLowercasedNames)
            let fileURL = stagingFolder.appendingPathComponent(fileName)
            let serialized = TunnelProfileCodec.serialize(profile)
            try Data(serialized.utf8).write(to: fileURL, options: .atomic)
        }

        var coordinationError: NSError?
        var copyError: Error?
        var didRunAccessor = false

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: stagingFolder,
            options: .forUploading,
            error: &coordinationError
        ) { zippedURL in
            didRunAccessor = true
            do {
                let destinationParent = destinationURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: zippedURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }

        if let coordinationError {
            throw ProfileArchiveExporterError.coordinationFailed(coordinationError.localizedDescription)
        }
        if let copyError {
            throw ProfileArchiveExporterError.copyFailed(copyError.localizedDescription)
        }
        guard didRunAccessor else {
            throw ProfileArchiveExporterError.coordinationFailed("File coordination did not produce an archive.")
        }
    }

    public static func sanitizedBaseName(for rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        var sanitized = ""
        sanitized.reserveCapacity(trimmed.count)

        for scalar in trimmed.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\\" || scalar.value < 0x20 || scalar.value == 0x7F {
                sanitized.append("-")
            } else {
                sanitized.unicodeScalars.append(scalar)
            }
        }

        while sanitized.hasPrefix(".") {
            sanitized.removeFirst()
        }
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.lowercased().hasSuffix(".conf") {
            sanitized = String(sanitized.dropLast(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sanitized.isEmpty ? "tunnel" : sanitized
    }

    private static func uniqueFileName(
        for rawName: String,
        usedLowercasedNames: inout Set<String>
    ) -> String {
        let base = sanitizedBaseName(for: rawName)
        var candidate = base
        var suffix = 2

        while !usedLowercasedNames.insert(candidate.lowercased()).inserted {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return "\(candidate).conf"
    }
}
