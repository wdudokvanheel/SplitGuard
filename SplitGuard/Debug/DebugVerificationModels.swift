#if DEBUG
import Foundation
import UIKit

enum AutomatedCheckID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case appGroupLogging
    case keychainProfileStore
    case codecAndZipExport
    case onDemandAndDraftValidation
    case neManagerCrudAndSort
    case startErrorProbe
    case quirk6BulkSaveNotifications
    case quirk4FreshStartAndEnabled
    case quirk3OnDemandReload
    case quirk1ActiveTunnelSave

    var id: String { rawValue }

    var category: String {
        switch self {
        case .appGroupLogging, .keychainProfileStore, .codecAndZipExport, .onDemandAndDraftValidation:
            return "Core & Storage"
        case .neManagerCrudAndSort, .startErrorProbe:
            return "NetworkExtension & Errors"
        case .quirk6BulkSaveNotifications, .quirk4FreshStartAndEnabled,
             .quirk3OnDemandReload, .quirk1ActiveTunnelSave:
            return "iOS 26 Quirk Probes"
        }
    }

    var title: String {
        switch self {
        case .appGroupLogging:
            return "App Group & Logging"
        case .keychainProfileStore:
            return "Keychain & ProfileStore"
        case .codecAndZipExport:
            return "Codec & Zip Export"
        case .onDemandAndDraftValidation:
            return "OnDemandPolicy & TunnelDraft"
        case .neManagerCrudAndSort:
            return "NETunnelProviderManager CRUD & Sort"
        case .startErrorProbe:
            return "Start Error: fetchLastDisconnectError vs IPC"
        case .quirk6BulkSaveNotifications:
            return "Quirk #6: Bulk Save Notifications"
        case .quirk4FreshStartAndEnabled:
            return "Quirk #4: Fresh Save Start & isEnabled"
        case .quirk3OnDemandReload:
            return "Quirk #3: On-Demand Without Reload"
        case .quirk1ActiveTunnelSave:
            return "Quirk #1: New Save While Active"
        }
    }

    var subtitle: String {
        switch self {
        case .appGroupLogging:
            return "SplitGuardAppGroupID, shared container RW, LogFile rotation & MergedLogReader"
        case .keychainProfileStore:
            return "ProfileStore save/load/verify/delete & NETunnelProviderProtocol fields"
        case .codecAndZipExport:
            return "TunnelProfileCodec round-trip + SplitGuard directives & PKZIP archive export"
        case .onDemandAndDraftValidation:
            return "OnDemandPolicy rules, RFC1918 helper, and TunnelDraft validation"
        case .neManagerCrudAndSort:
            return "Temporary manager create, load, natural sort, rename, and clean removal"
        case .startErrorProbe:
            return "Trigger NXDOMAIN start failure and compare fetchLastDisconnectError vs IPC"
        case .quirk6BulkSaveNotifications:
            return "Count NEVPNConfigurationChange notifications fired for 3 temp saves"
        case .quirk4FreshStartAndEnabled:
            return "Test immediate startTunnel without reload & isEnabled flip on second save"
        case .quirk3OnDemandReload:
            return "Test enabling on-demand without reload and check status / stale behavior"
        case .quirk1ActiveTunnelSave:
            return "Opt-in: save a temporary config while a real tunnel is active"
        }
    }
}

enum AutomatedCheckStatus: String, Equatable, Hashable, Sendable {
    case idle
    case running
    case passed
    case failed
    case info

    var badgeTitle: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .passed: return "Pass"
        case .failed: return "Fail"
        case .info: return "Info"
        }
    }
}

struct AutomatedCheckResult: Identifiable, Equatable, Sendable {
    let id: AutomatedCheckID
    var status: AutomatedCheckStatus
    var summary: String
    var detail: String
    var durationMilliseconds: Int?

    init(
        id: AutomatedCheckID,
        status: AutomatedCheckStatus = .idle,
        summary: String = "Not run yet",
        detail: String = "",
        durationMilliseconds: Int? = nil
    ) {
        self.id = id
        self.status = status
        self.summary = summary
        self.detail = detail
        self.durationMilliseconds = durationMilliseconds
    }
}

enum IOSQuirkID: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case saveNewDeactivatesActive = 1
    case onDemandOnRunningNeedsStop = 2
    case enableOnDemandNeedsReload = 3
    case startStaleOrDisabledManager = 4
    case missingStatusNotifications = 5
    case bulkSaveNotificationPerItem = 6

    var id: Int { rawValue }

    var shortLabel: String { "Quirk #\(rawValue)" }

    var descriptionText: String {
        switch self {
        case .saveNewDeactivatesActive:
            return "Saving a new VPN configuration deactivates the running tunnel."
        case .onDemandOnRunningNeedsStop:
            return "Introducing on-demand rules on a running tunnel requires stopping it first."
        case .enableOnDemandNeedsReload:
            return "After enabling on-demand, the manager must be reloaded or status updates stop."
        case .startStaleOrDisabledManager:
            return "startTunnel fails with configurationInvalid/Stale until reloaded; manager can become disabled."
        case .missingStatusNotifications:
            return "Status notifications can go missing while connecting (covered by 5s poll)."
        case .bulkSaveNotificationPerItem:
            return "Bulk saves trigger a configuration-change notification per item."
        }
    }
}

enum QuirkObservationStatus: String, Equatable, Hashable, Sendable {
    case notRun = "Not Run"
    case reproduced = "Reproduced"
    case notReproduced = "Not Reproduced"
    case needsActiveTunnel = "Needs Active Tunnel"
    case manualCheck = "Manual Check"
    case simulatorOnly = "Simulator (N/A)"
}

struct IOSQuirkFinding: Identifiable, Equatable, Sendable {
    let id: IOSQuirkID
    var status: QuirkObservationStatus
    var observation: String

    init(id: IOSQuirkID, status: QuirkObservationStatus = .notRun, observation: String = "") {
        self.id = id
        self.status = status
        self.observation = observation
    }
}

struct StartErrorProbeSummary: Equatable, Sendable {
    var fetchLastDisconnectRaw: String
    var fetchLastDisconnectDecoded: String?
    var ipcReply: String
    var ipcDecoded: String?
    var statusTransitions: [String]
    var verdictLine: String
}

enum ManualCheckVerdict: String, CaseIterable, Equatable, Hashable, Sendable {
    case pending
    case passed
    case failed
    case skipped

    var title: String {
        switch self {
        case .pending: return "Pending"
        case .passed: return "Pass"
        case .failed: return "Fail"
        case .skipped: return "Skip"
        }
    }
}

enum ManualStepID: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case importConfFile = 1
    case importQRCode = 2
    case pasteAndCreateFromScratch = 3
    case connectMetricsDisconnect = 4
    case switchAndEditConnected = 5
    case failedStartErrorReporting = 6
    case splitDNS = 7
    case killSwitch = 8
    case onDemandActivation = 9
    case deviceAuthAndZipExport = 10
    case externalIOSSettingsChanges = 11
    case homeScreenQuickActions = 12
    case logViewerAndExport = 13

    var id: Int { rawValue }
}

struct ManualStepDefinition: Identifiable, Equatable, Sendable {
    let id: ManualStepID
    let number: Int
    let title: String
    let subtitle: String
    let instructions: [String]
    let whatToVerify: String
}

struct ManualStepRecord: Equatable, Sendable {
    var verdict: ManualCheckVerdict = .pending
    var notes: String = ""
}

enum WizardStep: Identifiable, Equatable, Hashable, Sendable {
    case automatedDiagnostics
    case manual(ManualStepID)
    case summary

    var id: String {
        switch self {
        case .automatedDiagnostics:
            return "automated"
        case .manual(let stepID):
            return "manual-\(stepID.rawValue)"
        case .summary:
            return "summary"
        }
    }

    var shortTitle: String {
        switch self {
        case .automatedDiagnostics:
            return "Automated Checks"
        case .manual(let stepID):
            return DebugVerificationCatalog.definition(for: stepID).title
        case .summary:
            return "Summary & Report"
        }
    }

    static var allSteps: [WizardStep] {
        [.automatedDiagnostics] + ManualStepID.allCases.map { .manual($0) } + [.summary]
    }
}

struct DebugVerificationDeviceInfo: Equatable, Sendable {
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let deviceModel: String
    let isSimulator: Bool
    let generatedAt: Date

    @MainActor
    static func current(now: Date = Date()) -> DebugVerificationDeviceInfo {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let osVersion = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        return DebugVerificationDeviceInfo(
            appVersion: version,
            buildNumber: build,
            osVersion: osVersion,
            deviceModel: machine,
            isSimulator: simulator,
            generatedAt: now
        )
    }
}
#endif
