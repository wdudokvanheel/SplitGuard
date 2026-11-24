#if DEBUG
import SwiftUI
import UIKit

struct DebugVerificationSummaryPage: View {
    @Bindable var model: DebugVerificationWizardModel
    let onAction: (DebugWizardAction) -> Void

    @State private var copiedConfirmation = false
    @State private var showResetConfirmation = false

    private var deviceInfo: DebugVerificationDeviceInfo {
        DebugVerificationDeviceInfo.current()
    }

    var body: some View {
        VStack(spacing: SGSpacing.medium) {
            scorecardCard
            exportActionsCard
            startErrorSummaryCard
            quirksMatrixCard
            automatedResultsCard
            manualResultsCard
            resetButton
        }
        .alert("Reset All Verification Results?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                model.resetAll()
            }
        } message: {
            Text("This clears all automated results, manual verdicts, and notes so you can start a fresh pass.")
        }
    }

    private var scorecardCard: some View {
        VStack(alignment: .leading, spacing: SGSpacing.small) {
            BrutalistSectionBar(title: "Verification Summary", trailingText: deviceInfo.osVersion)

            VStack(alignment: .leading, spacing: SGSpacing.small) {
                Text("App v\(deviceInfo.appVersion) (\(deviceInfo.buildNumber)) • \(deviceInfo.deviceModel)")
                    .font(SGTypography.monoCompact)
                    .foregroundStyle(SGColor.textSecondary)

                HStack(spacing: SGSpacing.xSmall) {
                    metricBox(
                        title: "AUTO PASS",
                        value: "\(model.automatedPassCount)/\(model.automatedResults.count)",
                        fill: SGColor.popGreen
                    )
                    metricBox(
                        title: "AUTO FAIL",
                        value: "\(model.automatedFailCount)",
                        fill: model.automatedFailCount > 0 ? SGColor.popRed : SGColor.surfaceElevated
                    )
                }

                HStack(spacing: SGSpacing.xSmall) {
                    metricBox(
                        title: "MANUAL PASS",
                        value: "\(model.manualPassCount)/\(ManualStepID.allCases.count)",
                        fill: SGColor.popGreen
                    )
                    metricBox(
                        title: "FAIL / SKIP",
                        value: "\(model.manualFailCount) / \(model.manualSkippedCount)",
                        fill: model.manualFailCount > 0 ? SGColor.popRed : SGColor.popYellow
                    )
                }
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private var exportActionsCard: some View {
        VStack(spacing: SGSpacing.xSmall) {
            DebugActionButton(
                title: copiedConfirmation ? "MARKDOWN REPORT COPIED!" : "COPY MARKDOWN REPORT",
                icon: copiedConfirmation ? "checkmark" : "doc.on.doc.fill",
                fill: SGColor.popGreen
            ) {
                UIPasteboard.general.string = model.buildMarkdownReport(deviceInfo: deviceInfo)
                copiedConfirmation = true
            }

            DebugActionButton(
                title: "SHARE MARKDOWN REPORT",
                icon: "square.and.arrow.up",
                fill: SGColor.popYellow
            ) {
                let report = model.buildMarkdownReport(deviceInfo: deviceInfo)
                let fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("splitguard-device-verification.md")
                if (try? Data(report.utf8).write(to: fileURL, options: .atomic)) != nil {
                    onAction(.shareFile(fileURL))
                } else {
                    onAction(.shareText(report))
                }
            }
        }
    }

    private var startErrorSummaryCard: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: "Start Error Delivery")

            VStack(alignment: .leading, spacing: 4) {
                if let summary = model.startErrorSummary {
                    Text(summary.verdictLine)
                        .font(SGTypography.bodyBold)
                        .foregroundStyle(SGColor.textPrimary)
                    Text("fetchLastDisconnectError: \(summary.fetchLastDisconnectDecoded ?? summary.fetchLastDisconnectRaw)")
                        .font(SGTypography.monoCompact)
                        .foregroundStyle(SGColor.textSecondary)
                    Text("IPC fallback: \(summary.ipcDecoded ?? summary.ipcReply)")
                        .font(SGTypography.monoCompact)
                        .foregroundStyle(SGColor.textSecondary)
                } else {
                    Text("Not probed yet. Run Step 1 (Start Error probe) on a physical device.")
                        .font(SGTypography.caption)
                        .foregroundStyle(SGColor.textSecondary)
                }
            }
            .padding(SGSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private var quirksMatrixCard: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: "iOS 26 Quirk Findings", trailingText: "6 QUIRKS")

            VStack(spacing: SGSpacing.xSmall) {
                ForEach(model.quirkFindings) { finding in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(finding.id.shortLabel.uppercased())
                                .font(SGTypography.metricLabel)
                                .foregroundStyle(SGColor.textPrimary)
                            Spacer()
                            SGStatusBadge(
                                title: finding.status.rawValue,
                                color: quirkBadgeColor(finding.status),
                                isInactive: finding.status == .notRun || finding.status == .simulatorOnly
                            )
                        }
                        Text(finding.observation.isEmpty ? finding.id.descriptionText : finding.observation)
                            .font(SGTypography.caption)
                            .foregroundStyle(SGColor.textSecondary)
                    }
                    .padding(SGSpacing.xSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SGColor.surfaceElevated)
                    .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
                }
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private var automatedResultsCard: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: "Automated Checks", trailingText: "TAP TO REVIEW")

            VStack(spacing: SGSpacing.xSmall) {
                ForEach(model.automatedResults) { result in
                    Button {
                        model.jumpTo(step: .automatedDiagnostics)
                    } label: {
                        HStack(spacing: SGSpacing.xSmall) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.id.title)
                                    .font(SGTypography.subheadline.weight(.bold))
                                    .foregroundStyle(SGColor.textPrimary)
                                Text(result.summary)
                                    .font(SGTypography.caption)
                                    .foregroundStyle(SGColor.textSecondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            SGStatusBadge(
                                title: result.status.badgeTitle,
                                color: automatedBadgeColor(result.status),
                                isInactive: result.status == .idle
                            )
                        }
                        .padding(SGSpacing.xSmall)
                        .background(SGColor.surfaceElevated)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private var manualResultsCard: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: "Manual Checks (1-13)", trailingText: "TAP TO EDIT")

            VStack(spacing: SGSpacing.xSmall) {
                ForEach(DebugVerificationCatalog.manualSteps) { def in
                    let rec = model.record(for: def.id)
                    Button {
                        model.jumpTo(step: .manual(def.id))
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: SGSpacing.xSmall) {
                                Text("\(def.number). \(def.title)")
                                    .font(SGTypography.subheadline.weight(.bold))
                                    .foregroundStyle(SGColor.textPrimary)
                                Spacer()
                                SGStatusBadge(
                                    title: rec.verdict.title,
                                    color: manualBadgeColor(rec.verdict),
                                    isInactive: rec.verdict == .pending
                                )
                            }
                            let trimmed = rec.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                Text(trimmed)
                                    .font(SGTypography.caption)
                                    .foregroundStyle(SGColor.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(SGSpacing.xSmall)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SGColor.surfaceElevated)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private var resetButton: some View {
        DebugActionButton(
            title: "RESET ALL VERIFICATION RESULTS",
            icon: "arrow.counterclockwise",
            fill: SGColor.popRed,
            foreground: SGColor.pureWhite
        ) {
            showResetConfirmation = true
        }
    }
}

private extension DebugVerificationSummaryPage {
    func metricBox(title: String, value: String, fill: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(SGTypography.metricLabel)
                .tracking(0.6)
            Text(value)
                .font(SGTypography.displaySection)
                .tracking(0.8)
        }
        .foregroundStyle(fill == SGColor.surfaceElevated ? SGColor.textPrimary : SGColor.inkOnPop)
        .padding(SGSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
    }

    func automatedBadgeColor(_ status: AutomatedCheckStatus) -> Color {
        switch status {
        case .idle: return SGColor.surfaceElevated
        case .running: return SGColor.popYellow
        case .passed: return SGColor.popGreen
        case .failed: return SGColor.popRed
        case .info: return SGColor.popBlue
        }
    }

    func manualBadgeColor(_ verdict: ManualCheckVerdict) -> Color {
        switch verdict {
        case .pending: return SGColor.surfaceElevated
        case .passed: return SGColor.popGreen
        case .failed: return SGColor.popRed
        case .skipped: return SGColor.popYellow
        }
    }

    func quirkBadgeColor(_ status: QuirkObservationStatus) -> Color {
        switch status {
        case .reproduced: return SGColor.popRed
        case .notReproduced: return SGColor.popGreen
        case .needsActiveTunnel, .manualCheck: return SGColor.popYellow
        case .notRun, .simulatorOnly: return SGColor.surfaceElevated
        }
    }
}
#endif
