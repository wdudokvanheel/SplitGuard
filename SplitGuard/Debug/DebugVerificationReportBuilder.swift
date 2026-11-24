#if DEBUG
import Foundation

enum DebugVerificationReportBuilder {
    static func buildMarkdown(
        deviceInfo: DebugVerificationDeviceInfo,
        automatedResults: [AutomatedCheckResult],
        quirkFindings: [IOSQuirkFinding],
        startErrorSummary: StartErrorProbeSummary?,
        manualRecords: [ManualStepID: ManualStepRecord]
    ) -> String {
        var lines: [String] = []
        lines.append("# SplitGuard Physical-Device Verification Report")
        lines.append("")
        appendEnvironmentSection(to: &lines, deviceInfo: deviceInfo)
        appendOverviewSection(to: &lines, automatedResults: automatedResults, manualRecords: manualRecords)
        appendStartErrorSection(to: &lines, startErrorSummary: startErrorSummary)
        appendQuirksSection(to: &lines, quirkFindings: quirkFindings)
        appendAutomatedSection(to: &lines, automatedResults: automatedResults)
        appendManualSection(to: &lines, manualRecords: manualRecords)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendEnvironmentSection(
        to lines: inout [String],
        deviceInfo: DebugVerificationDeviceInfo
    ) {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let timestamp = isoFormatter.string(from: deviceInfo.generatedAt)
        let runtimeKind = deviceInfo.isSimulator ? "iOS Simulator" : "Physical iOS Device"

        lines.append("## Environment")
        lines.append("- **App Version**: \(deviceInfo.appVersion) (\(deviceInfo.buildNumber))")
        lines.append("- **OS**: \(deviceInfo.osVersion)")
        lines.append("- **Device**: \(deviceInfo.deviceModel) (\(runtimeKind))")
        lines.append("- **Generated**: \(timestamp)")
        lines.append("")
    }

    private static func appendOverviewSection(
        to lines: inout [String],
        automatedResults: [AutomatedCheckResult],
        manualRecords: [ManualStepID: ManualStepRecord]
    ) {
        let autoPass = automatedResults.filter { $0.status == .passed }.count
        let autoFail = automatedResults.filter { $0.status == .failed }.count
        let autoInfo = automatedResults.filter { $0.status == .info }.count
        let autoIdle = automatedResults.filter { $0.status == .idle || $0.status == .running }.count

        let manualVerdicts = ManualStepID.allCases.map { manualRecords[$0]?.verdict ?? .pending }
        let manPass = manualVerdicts.filter { $0 == .passed }.count
        let manFail = manualVerdicts.filter { $0 == .failed }.count
        let manSkip = manualVerdicts.filter { $0 == .skipped }.count
        let manPending = manualVerdicts.filter { $0 == .pending }.count

        lines.append("## Summary")
        lines.append(
            "- **Automated Checks (\(automatedResults.count))**: "
                + "\(autoPass) passed, \(autoFail) failed, \(autoInfo) info, \(autoIdle) not run"
        )
        lines.append(
            "- **Manual Checks (\(ManualStepID.allCases.count))**: "
                + "\(manPass) passed, \(manFail) failed, \(manSkip) skipped, \(manPending) pending"
        )
        lines.append("")
    }

    private static func appendStartErrorSection(
        to lines: inout [String],
        startErrorSummary: StartErrorProbeSummary?
    ) {
        lines.append("## Start Error Delivery (`fetchLastDisconnectError` vs IPC)")
        guard let summary = startErrorSummary else {
            lines.append("- Not probed yet.")
            lines.append("")
            return
        }
        lines.append("- **Verdict**: \(summary.verdictLine)")
        lines.append("- **fetchLastDisconnectError raw**: \(summary.fetchLastDisconnectRaw)")
        lines.append("- **fetchLastDisconnectError decoded**: \(summary.fetchLastDisconnectDecoded ?? "nil")")
        lines.append("- **ProviderMessage.lastStartError reply**: \(summary.ipcReply)")
        lines.append("- **ProviderMessage.lastStartError decoded**: \(summary.ipcDecoded ?? "nil")")
        if !summary.statusTransitions.isEmpty {
            lines.append("- **NEVPNStatus transitions**: \(summary.statusTransitions.joined(separator: " -> "))")
        }
        lines.append("")
    }

    private static func appendQuirksSection(
        to lines: inout [String],
        quirkFindings: [IOSQuirkFinding]
    ) {
        lines.append("## iOS 26 Quirk Findings")
        lines.append("| Quirk | Status | Observation |")
        lines.append("| --- | --- | --- |")
        for quirk in IOSQuirkID.allCases {
            let finding = quirkFindings.first { $0.id == quirk } ?? IOSQuirkFinding(id: quirk)
            let obs = sanitizeTableCell(finding.observation.isEmpty ? quirk.descriptionText : finding.observation)
            lines.append("| \(quirk.shortLabel) | \(finding.status.rawValue) | \(obs) |")
        }
        lines.append("")
    }

    private static func appendAutomatedSection(
        to lines: inout [String],
        automatedResults: [AutomatedCheckResult]
    ) {
        lines.append("## Automated Checks")
        lines.append("| Check | Status | Duration | Summary |")
        lines.append("| --- | --- | --- | --- |")
        for result in automatedResults {
            let durationText = result.durationMilliseconds.map { "\($0) ms" } ?? "-"
            lines.append(
                "| \(sanitizeTableCell(result.id.title)) | \(result.status.badgeTitle.uppercased()) "
                    + "| \(durationText) | \(sanitizeTableCell(result.summary)) |"
            )
        }
        let detailedResults = automatedResults.filter { !$0.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !detailedResults.isEmpty {
            lines.append("")
            lines.append("### Automated Check Details")
            for result in detailedResults {
                lines.append("- **\(result.id.title)** (\(result.status.badgeTitle.uppercased())):")
                for detailLine in result.detail.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("  - \(detailLine)")
                }
            }
        }
        lines.append("")
    }

    private static func appendManualSection(
        to lines: inout [String],
        manualRecords: [ManualStepID: ManualStepRecord]
    ) {
        lines.append("## Manual Verification Checks")
        lines.append("| # | Test | Verdict | Notes |")
        lines.append("| --- | --- | --- | --- |")
        for definition in DebugVerificationCatalog.manualSteps {
            let record = manualRecords[definition.id] ?? ManualStepRecord()
            let notes = record.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let notesCell = notes.isEmpty ? "-" : sanitizeTableCell(notes)
            lines.append(
                "| \(definition.number) | \(sanitizeTableCell(definition.title)) "
                    + "| \(record.verdict.title.uppercased()) | \(notesCell) |"
            )
        }
    }

    private static func sanitizeTableCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
