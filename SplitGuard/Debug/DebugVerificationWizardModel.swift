#if DEBUG
import Foundation
import Observation

@MainActor
@Observable
final class DebugVerificationWizardModel {
    static let shared = DebugVerificationWizardModel()

    let steps: [WizardStep] = WizardStep.allSteps
    var currentStepIndex: Int = 0
    var automatedResults: [AutomatedCheckResult]
    var quirkFindings: [IOSQuirkFinding]
    var startErrorSummary: StartErrorProbeSummary?
    var manualRecords: [ManualStepID: ManualStepRecord]
    var isRunningAutomatedSuite = false
    var allowActiveTunnelQuirkProbe = false
    var lastCleanupMessage: String?

    init() {
        self.automatedResults = AutomatedCheckID.allCases.map { AutomatedCheckResult(id: $0) }
        self.quirkFindings = Self.initialQuirkFindings()
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
        quirkFindings = Self.initialQuirkFindings()
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

    func runAutomatedCheck(_ checkID: AutomatedCheckID, store: TunnelStore) async {
        updateAutomatedResult(
            AutomatedCheckResult(id: checkID, status: .running, summary: "Running check...")
        )

        switch checkID {
        case .appGroupLogging:
            let result = DebugVerificationCoreChecks.runAppGroupAndLoggingCheck()
            updateAutomatedResult(result)
        case .keychainProfileStore:
            let result = DebugVerificationCoreChecks.runKeychainAndProfileStoreCheck()
            updateAutomatedResult(result)
        case .codecAndZipExport:
            let result = DebugVerificationCoreChecks.runCodecAndZipExportCheck()
            updateAutomatedResult(result)
        case .onDemandAndDraftValidation:
            let result = DebugVerificationCoreChecks.runOnDemandAndDraftValidationCheck()
            updateAutomatedResult(result)
        case .neManagerCrudAndSort:
            let outcome = await DebugVerificationNetworkChecks.runManagerCRUDAndSortCheck(store: store)
            applyNetworkOutcome(outcome)
        case .startErrorProbe:
            let outcome = await DebugVerificationNetworkChecks.runStartErrorProbe(store: store)
            applyNetworkOutcome(outcome)
        case .quirk6BulkSaveNotifications:
            let outcome = await DebugVerificationNetworkChecks.runQuirk6BulkSaveCheck(store: store)
            applyNetworkOutcome(outcome)
        case .quirk4FreshStartAndEnabled:
            let outcome = await DebugVerificationNetworkChecks.runQuirk4FreshStartAndEnabledCheck(store: store)
            applyNetworkOutcome(outcome)
        case .quirk3OnDemandReload:
            let outcome = await DebugVerificationNetworkChecks.runQuirk3OnDemandReloadCheck(store: store)
            applyNetworkOutcome(outcome)
        case .quirk1ActiveTunnelSave:
            let outcome = await DebugVerificationNetworkChecks.runQuirk1ActiveTunnelSaveCheck(
                store: store,
                allowActiveTunnelInterruption: allowActiveTunnelQuirkProbe
            )
            applyNetworkOutcome(outcome)
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

    private func updateAutomatedResult(_ result: AutomatedCheckResult) {
        if let idx = automatedResults.firstIndex(where: { $0.id == result.id }) {
            automatedResults[idx] = result
        }
    }

    private func applyNetworkOutcome(_ outcome: NetworkCheckOutcome) {
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

    private static func initialQuirkFindings() -> [IOSQuirkFinding] {
        IOSQuirkID.allCases.map { quirk in
            if quirk == .onDemandOnRunningNeedsStop {
                return IOSQuirkFinding(
                    id: quirk,
                    status: .manualCheck,
                    observation: "Verify on Manual Step 9 (add on-demand rules to a running tunnel)."
                )
            }
            return IOSQuirkFinding(id: quirk, status: .notRun, observation: "")
        }
    }
}
#endif
