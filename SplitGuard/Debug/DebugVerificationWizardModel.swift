#if DEBUG
import Foundation
import Observation
import SplitGuardCore
import UIKit

@MainActor
@Observable
final class DebugVerificationWizardModel {
    static let shared = DebugVerificationWizardModel()
    static let autoRunLaunchFlag = "--run-debug-wizard"
    static let cliReportFileName = "splitguard-debug-wizard-report.md"
    static let cliStatusFileName = "splitguard-debug-wizard-status.txt"
    static let cliLogsFileName = "splitguard-debug-wizard-logs.txt"

    let steps: [WizardStep] = WizardStep.allSteps
    var currentStepIndex: Int = 0
    var automatedResults: [AutomatedCheckResult]
    var quirkFindings: [IOSQuirkFinding]
    var startErrorSummary: StartErrorProbeSummary?
    var manualRecords: [ManualStepID: ManualStepRecord]
    var isRunningAutomatedSuite = false
    var lastCleanupMessage: String?
    private var didStartAutoRun = false

    init() {
        self.automatedResults = AutomatedCheckID.allCases.map { AutomatedCheckResult(id: $0) }
        self.quirkFindings = IOSQuirkID.allCases.map { IOSQuirkFinding(id: $0) }
        var records: [ManualStepID: ManualStepRecord] = [:]
        for stepID in ManualStepID.allCases {
            records[stepID] = ManualStepRecord()
        }
        self.manualRecords = records
    }

    var currentStep: WizardStep {
        steps[max(0, min(currentStepIndex, steps.count - 1))]
    }

    var stepCount: Int { steps.count }
    var canGoBack: Bool { currentStepIndex > 0 }
    var canGoNext: Bool { currentStepIndex < steps.count - 1 }

    var progressFraction: Double {
        guard steps.count > 1 else { return 1.0 }
        return Double(currentStepIndex + 1) / Double(steps.count)
    }

    func goNext() {
        guard canGoNext else { return }
        currentStepIndex += 1
    }

    func goBack() {
        guard canGoBack else { return }
        currentStepIndex -= 1
    }

    func jumpTo(stepIndex: Int) {
        guard steps.indices.contains(stepIndex) else { return }
        currentStepIndex = stepIndex
    }

    func jumpTo(step: WizardStep) {
        if let index = steps.firstIndex(of: step) {
            currentStepIndex = index
        }
    }

    func result(for id: AutomatedCheckID) -> AutomatedCheckResult {
        automatedResults.first { $0.id == id } ?? AutomatedCheckResult(id: id)
    }

    func record(for id: ManualStepID) -> ManualStepRecord {
        manualRecords[id] ?? ManualStepRecord()
    }

    func setVerdict(_ verdict: ManualCheckVerdict, for id: ManualStepID) {
        var current = manualRecords[id] ?? ManualStepRecord()
        current.verdict = verdict
        manualRecords[id] = current
    }

    func setNotes(_ notes: String, for id: ManualStepID) {
        var current = manualRecords[id] ?? ManualStepRecord()
        current.notes = notes
        manualRecords[id] = current
    }

    func resetAll() {
        currentStepIndex = 0
        automatedResults = AutomatedCheckID.allCases.map { AutomatedCheckResult(id: $0) }
        quirkFindings = IOSQuirkID.allCases.map { IOSQuirkFinding(id: $0) }
        startErrorSummary = nil
        lastCleanupMessage = nil
        for stepID in ManualStepID.allCases {
            manualRecords[stepID] = ManualStepRecord()
        }
    }

    func runAllAutomatedChecks(store: TunnelStore) async {
        guard !isRunningAutomatedSuite else { return }
        isRunningAutomatedSuite = true
        defer { isRunningAutomatedSuite = false }

        for checkID in AutomatedCheckID.allCases {
            await runAutomatedCheck(checkID, store: store)
        }
    }

    func runAutomatedSuiteForCLI(store: TunnelStore) async {
        guard !didStartAutoRun else { return }
        didStartAutoRun = true

        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        resetAll()
        writeCLIStatus("STARTING")

        let deadline = ContinuousClock.now + .seconds(15)
        while !store.hasLoaded && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }

        isRunningAutomatedSuite = true
        defer { isRunningAutomatedSuite = false }

        for (index, checkID) in AutomatedCheckID.allCases.enumerated() {
            let total = AutomatedCheckID.allCases.count
            writeCLIStatus("RUNNING \(index + 1)/\(total): \(checkID.rawValue)")
            await runAutomatedCheck(checkID, store: store)
            let checkResult = result(for: checkID)
            let durationText = checkResult.durationMilliseconds.map { "\($0)ms" } ?? "-"
            let badge = checkResult.status.badgeTitle.uppercased()
            print("[DEBUG-WIZARD] [\(index + 1)/\(total)] \(checkID.rawValue): \(badge) (\(durationText)) - \(checkResult.summary)")
            writeCLIReport()
        }

        writeCLIReport()
        writeCLIMergedLogs()
        Log.flush()
        writeCLIStatus("DONE pass=\(automatedPassCount) fail=\(automatedFailCount) info=\(automatedInfoCount)")
        print("[DEBUG-WIZARD] COMPLETE pass=\(automatedPassCount) fail=\(automatedFailCount) info=\(automatedInfoCount)")
    }

    private func writeCLIStatus(_ text: String) {
        let url = URL.cachesDirectory.appendingPathComponent(Self.cliStatusFileName)
        try? Data((text + "\n").utf8).write(to: url, options: .atomic)
    }

    private func writeCLIReport() {
        let url = URL.cachesDirectory.appendingPathComponent(Self.cliReportFileName)
        let markdown = buildMarkdownReport()
        try? Data(markdown.utf8).write(to: url, options: .atomic)
    }

    private func writeCLIMergedLogs() {
        guard let dir = AppGroup.containerURL() else { return }
        let url = URL.cachesDirectory.appendingPathComponent(Self.cliLogsFileName)
        let reader = MergedLogReader(directoryURL: dir)
        try? reader.writeExport(to: url)
    }

    func runAutomatedCheck(_ checkID: AutomatedCheckID, store: TunnelStore) async {
        updateAutomatedResult(
            AutomatedCheckResult(id: checkID, status: .running, summary: "Running check...")
        )
        if let coreResult = await runCoreCheck(checkID) {
            updateAutomatedResult(coreResult)
            return
        }
        if let liveOutcome = await runLiveCheck(checkID, store: store) {
            applyNetworkOutcome(liveOutcome)
            return
        }
        if let quirkOutcome = await runQuirkCheck(checkID, store: store) {
            applyNetworkOutcome(quirkOutcome)
        }
    }

    func cleanupProbeTunnels(store: TunnelStore) async {
        let removed = await DebugVerificationNetworkChecks.cleanupAllProbeManagers(store: store)
        lastCleanupMessage = removed == 0
            ? "No leftover temporary probe tunnels found."
            : "Removed \(removed) temporary probe tunnel(s)."
    }

    func buildMarkdownReport(deviceInfo: DebugVerificationDeviceInfo? = nil) -> String {
        let info = deviceInfo ?? DebugVerificationDeviceInfo.current()
        return DebugVerificationReportBuilder.buildMarkdown(
            deviceInfo: info,
            automatedResults: automatedResults,
            quirkFindings: quirkFindings,
            startErrorSummary: startErrorSummary,
            manualRecords: manualRecords
        )
    }

    var automatedPassCount: Int { automatedResults.filter { $0.status == .passed }.count }
    var automatedFailCount: Int { automatedResults.filter { $0.status == .failed }.count }
    var automatedInfoCount: Int { automatedResults.filter { $0.status == .info }.count }

    var manualPassCount: Int {
        ManualStepID.allCases.filter { manualRecords[$0]?.verdict == .passed }.count
    }
    var manualFailCount: Int {
        ManualStepID.allCases.filter { manualRecords[$0]?.verdict == .failed }.count
    }
    var manualSkippedCount: Int {
        ManualStepID.allCases.filter { manualRecords[$0]?.verdict == .skipped }.count
    }
    var manualPendingCount: Int {
        ManualStepID.allCases.filter { (manualRecords[$0]?.verdict ?? .pending) == .pending }.count
    }
}

private extension DebugVerificationWizardModel {
    func runCoreCheck(_ checkID: AutomatedCheckID) async -> AutomatedCheckResult? {
        switch checkID {
        case .zeroKeyBoundary, .mtuBoundary, .liveVerdictFixtures:
            return DebugVerificationCoreChecks.reviewRegression(checkID)
        case .appGroupLogging:
            return DebugVerificationCoreChecks.runAppGroupAndLoggingCheck()
        case .keychainProfileStore:
            return DebugVerificationCoreChecks.runKeychainAndProfileStoreCheck()
        case .codecAndZipExport:
            return DebugVerificationCoreChecks.runCodecAndZipExportCheck()
        case .onDemandAndDraftValidation:
            return DebugVerificationCoreChecks.runOnDemandAndDraftValidationCheck()
        case .importPasteCreateAndSort:
            return await DebugVerificationCoreChecks.runImportPasteCreateAndSortCheck()
        default:
            return nil
        }
    }

    func runLiveCheck(_ checkID: AutomatedCheckID, store: TunnelStore) async -> NetworkCheckOutcome? {
        switch checkID {
        case .transientProfileRead:
            return await DebugVerificationNetworkChecks.runProfileRecovery(store: store)
        case .neManagerCrudAndSort:
            return await DebugVerificationNetworkChecks.runManagerCRUDAndSortCheck(store: store)
        case .liveConnectMetricsDisconnect:
            return await DebugVerificationLiveChecks.runLiveConnectMetricsDisconnect(store: store)
        case .liveSwitchAndEditConnected:
            return await DebugVerificationLiveChecks.runLiveSwitchAndEditConnected(store: store)
        case .liveSplitDNSAndProbe:
            return await DebugVerificationLiveChecks.runLiveSplitDNSAndProbe(store: store)
        case .liveKillSwitchAndEndpointCache:
            return await DebugVerificationLiveChecks.runLiveKillSwitchAndEndpointCache(store: store)
        case .startErrorProbe:
            return await DebugVerificationNetworkChecks.runStartErrorProbe(store: store)
        case .liveMergedLogs:
            return DebugVerificationLiveChecks.runLiveMergedLogsCheck()
        default:
            return nil
        }
    }

    func runQuirkCheck(_ checkID: AutomatedCheckID, store: TunnelStore) async -> NetworkCheckOutcome? {
        switch checkID {
        case .quirk1ActiveTunnelSave:
            return await DebugVerificationNetworkChecks.runQuirk1ActiveTunnelSaveCheck(store: store)
        case .quirk2AddOnDemandRunning:
            return await DebugVerificationNetworkChecks.runQuirk2AddOnDemandRunningCheck(store: store)
        case .quirk3OnDemandReload:
            return await DebugVerificationNetworkChecks.runQuirk3OnDemandReloadCheck(store: store)
        case .quirk4FreshStartAndEnabled:
            return await DebugVerificationNetworkChecks.runQuirk4FreshStartAndEnabledCheck(store: store)
        case .quirk6BulkSaveNotifications:
            return await DebugVerificationNetworkChecks.runQuirk6BulkSaveCheck(store: store)
        default:
            return nil
        }
    }

    func updateAutomatedResult(_ result: AutomatedCheckResult) {
        if let idx = automatedResults.firstIndex(where: { $0.id == result.id }) {
            automatedResults[idx] = result
        }
    }

    func applyNetworkOutcome(_ outcome: NetworkCheckOutcome) {
        updateAutomatedResult(outcome.result)
        if let summary = outcome.startErrorSummary {
            startErrorSummary = summary
        }
        for finding in outcome.updatedQuirks {
            if let idx = quirkFindings.firstIndex(where: { $0.id == finding.id }) {
                quirkFindings[idx] = finding
            }
        }
    }
}
#endif
