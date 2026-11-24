#if DEBUG
import SwiftUI

struct DebugAutomatedChecksPage: View {
    @Bindable var model: DebugVerificationWizardModel
    let store: TunnelStore

    private var groupedCategories: [(title: String, checks: [AutomatedCheckResult])] {
        let order = ["Core & Storage", "NetworkExtension & Errors", "iOS 26 Quirk Probes"]
        return order.compactMap { category in
            let items = model.automatedResults.filter { $0.id.category == category }
            return items.isEmpty ? nil : (category, items)
        }
    }

    var body: some View {
        VStack(spacing: SGSpacing.medium) {
            heroActionCard
            quirkOptInCard

            if let startErrorSummary = model.startErrorSummary {
                startErrorHighlightCard(startErrorSummary)
            }

            ForEach(groupedCategories, id: \.title) { group in
                VStack(spacing: SGSpacing.small) {
                    BrutalistSectionBar(
                        title: group.title,
                        trailingText: "\(group.checks.filter { $0.status == .passed }.count)/\(group.checks.count)"
                    )

                    ForEach(group.checks) { check in
                        AutomatedCheckCard(
                            result: check,
                            isSuiteRunning: model.isRunningAutomatedSuite
                        ) {
                            Task {
                                await model.runAutomatedCheck(check.id, store: store)
                            }
                        }
                    }
                }
            }
        }
    }

    private var heroActionCard: some View {
        VStack(alignment: .leading, spacing: SGSpacing.small) {
            HStack(spacing: SGSpacing.small) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AUTOMATED DIAGNOSTICS")
                        .font(SGTypography.displaySection)
                        .tracking(1.0)
                        .foregroundStyle(SGColor.textPrimary)
                    Text("Self-cleaning on-device checks for Core, Keychain, Codec, Zip, NetworkExtension & iOS 26 quirks.")
                        .font(SGTypography.caption)
                        .foregroundStyle(SGColor.textSecondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: SGSpacing.xSmall) {
                scoreChip(label: "PASS", value: "\(model.automatedPassCount)", fill: SGColor.popGreen)
                scoreChip(label: "FAIL", value: "\(model.automatedFailCount)", fill: SGColor.popRed)
                scoreChip(label: "INFO", value: "\(model.automatedInfoCount)", fill: SGColor.popBlue)
            }

            Button {
                Task {
                    await model.runAllAutomatedChecks(store: store)
                }
            } label: {
                HStack(spacing: SGSpacing.xSmall) {
                    if model.isRunningAutomatedSuite {
                        ProgressView()
                            .controlSize(.small)
                            .tint(SGColor.inkOnPop)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.subheadline.weight(.black))
                    }
                    Text(model.isRunningAutomatedSuite ? "RUNNING SUITE..." : "RUN ALL AUTOMATED CHECKS")
                        .font(SGTypography.displayCompact)
                        .tracking(0.8)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, SGSpacing.medium)
            }
            .buttonStyle(
                BrutalistButtonStyle(
                    fill: SGColor.popGreen,
                    foreground: SGColor.inkOnPop,
                    borderWidth: SGBorder.regular,
                    shadowOffset: SGShadow.small,
                    fullWidth: true,
                    showGrain: true
                )
            )
            .disabled(model.isRunningAutomatedSuite)

            Button {
                Task {
                    await model.cleanupProbeTunnels(store: store)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash.fill")
                        .font(.caption.weight(.bold))
                    Text("CLEAN UP TEMPORARY PROBE TUNNELS")
                        .font(SGTypography.metricLabel)
                        .tracking(0.8)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, SGSpacing.small)
            }
            .buttonStyle(
                BrutalistButtonStyle(
                    fill: SGColor.surfaceElevated,
                    foreground: SGColor.textPrimary,
                    borderWidth: SGBorder.thin,
                    shadowOffset: 2,
                    fullWidth: true
                )
            )
            .disabled(model.isRunningAutomatedSuite)

            if let cleanup = model.lastCleanupMessage {
                Text(cleanup)
                    .font(SGTypography.monoCompact)
                    .foregroundStyle(SGColor.textSecondary)
            }
        }
        .padding(SGSpacing.medium)
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private var quirkOptInCard: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
            BrutalistFormToggleRow(
                title: "Allow Active-Tunnel Quirk #1 Probe",
                subtitle: "When ON and a real VPN is connected, saves a temp config to check if iOS 26 drops the active tunnel.",
                isOn: $model.allowActiveTunnelQuirkProbe,
                activeTint: SGColor.popYellow
            )
        }
        .padding(.horizontal, SGSpacing.medium)
        .padding(.vertical, SGSpacing.small)
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private func startErrorHighlightCard(_ summary: StartErrorProbeSummary) -> some View {
        VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
            BrutalistSectionBar(title: "Start Error Delivery Finding", trailingText: "iOS 26")

            VStack(alignment: .leading, spacing: 6) {
                Text(summary.verdictLine)
                    .font(SGTypography.bodyBold)
                    .foregroundStyle(SGColor.textPrimary)

                Text("fetchLastDisconnectError: \(summary.fetchLastDisconnectDecoded ?? summary.fetchLastDisconnectRaw)")
                    .font(SGTypography.monoCompact)
                    .foregroundStyle(SGColor.textSecondary)

                Text("ProviderMessage.lastStartError: \(summary.ipcDecoded ?? summary.ipcReply)")
                    .font(SGTypography.monoCompact)
                    .foregroundStyle(SGColor.textSecondary)

                if !summary.statusTransitions.isEmpty {
                    Text("Transitions: \(summary.statusTransitions.joined(separator: " -> "))")
                        .font(SGTypography.monoCompact)
                        .foregroundStyle(SGColor.textTertiary)
                }
            }
            .padding(SGSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private func scoreChip(label: String, value: String, fill: Color) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(SGTypography.metricLabel)
                .tracking(0.6)
            Text(value)
                .font(SGTypography.metricValue)
        }
        .foregroundStyle(SGColor.inkOnPop)
        .padding(.horizontal, SGSpacing.xSmall)
        .padding(.vertical, 5)
        .background(fill)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
    }
}

private struct AutomatedCheckCard: View {
    let result: AutomatedCheckResult
    let isSuiteRunning: Bool
    let onRun: () -> Void

    @State private var isExpanded = false

    private var badgeColor: Color {
        switch result.status {
        case .idle: return SGColor.surfaceElevated
        case .running: return SGColor.popYellow
        case .passed: return SGColor.popGreen
        case .failed: return SGColor.popRed
        case .info: return SGColor.popBlue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
            HStack(alignment: .top, spacing: SGSpacing.xSmall) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.id.title)
                        .font(SGTypography.cardTitle)
                        .foregroundStyle(SGColor.textPrimary)
                    Text(result.id.subtitle)
                        .font(SGTypography.caption)
                        .foregroundStyle(SGColor.textSecondary)
                }
                Spacer(minLength: SGSpacing.xSmall)
                SGStatusBadge(
                    title: result.status.badgeTitle,
                    color: badgeColor,
                    isAnimated: result.status == .running,
                    isInactive: result.status == .idle
                )
            }

            if result.status != .idle {
                HStack(alignment: .firstTextBaseline, spacing: SGSpacing.xSmall) {
                    Text(result.summary)
                        .font(SGTypography.subheadline)
                        .foregroundStyle(result.status == .failed ? SGColor.popRed : SGColor.textPrimary)
                    Spacer(minLength: 0)
                    if let milliseconds = result.durationMilliseconds {
                        Text("\(milliseconds) ms")
                            .font(SGTypography.monoCompact)
                            .foregroundStyle(SGColor.textTertiary)
                    }
                }
            }

            HStack(spacing: SGSpacing.xSmall) {
                Button(action: onRun) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.black))
                        Text(result.status == .idle ? "RUN" : "RE-RUN")
                            .font(SGTypography.metricLabel)
                            .tracking(0.8)
                    }
                    .padding(.horizontal, SGSpacing.small)
                    .padding(.vertical, 6)
                }
                .buttonStyle(
                    BrutalistButtonStyle(
                        fill: SGColor.popYellow,
                        foreground: SGColor.inkOnPop,
                        borderWidth: SGBorder.thin,
                        shadowOffset: 2
                    )
                )
                .disabled(isSuiteRunning || result.status == .running)

                if !result.detail.isEmpty {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Text(isExpanded ? "HIDE DETAILS" : "SHOW DETAILS")
                            .font(SGTypography.metricLabel)
                            .tracking(0.6)
                            .foregroundStyle(SGColor.textPrimary)
                            .padding(.horizontal, SGSpacing.xSmall)
                            .padding(.vertical, 6)
                            .background(SGColor.surfaceElevated)
                            .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            if isExpanded && !result.detail.isEmpty {
                Text(result.detail)
                    .font(SGTypography.monoCompact)
                    .foregroundStyle(SGColor.textPrimary)
                    .textSelection(.enabled)
                    .padding(SGSpacing.xSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SGColor.surfaceElevated)
                    .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
            }
        }
        .padding(SGSpacing.medium)
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }
}
#endif
