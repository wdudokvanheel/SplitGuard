#if DEBUG
import SwiftUI

struct DebugManualStepPage: View {
    @Bindable var model: DebugVerificationWizardModel
    let stepID: ManualStepID
    let store: TunnelStore
    let onAction: (DebugWizardAction) -> Void

    private var definition: ManualStepDefinition {
        DebugVerificationCatalog.definition(for: stepID)
    }

    private var record: ManualStepRecord {
        model.record(for: stepID)
    }

    var body: some View {
        VStack(spacing: SGSpacing.medium) {
            overviewBanner
            instructionsCard
            DebugManualStepToolbox(
                model: model,
                stepID: stepID,
                store: store,
                onAction: onAction
            )
            verdictAndNotesCard
        }
    }

    private var overviewBanner: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
            HStack(spacing: SGSpacing.xSmall) {
                Text("MANUAL TEST \(definition.number) OF \(ManualStepID.allCases.count)")
                    .font(SGTypography.metricLabel)
                    .tracking(0.8)
                    .foregroundStyle(SGColor.inkOnPop)
                    .padding(.horizontal, SGSpacing.xSmall)
                    .padding(.vertical, 3)
                    .background(SGColor.popYellow)
                    .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))

                Spacer(minLength: 0)

                verdictBadge(record.verdict)
            }

            Text(definition.title.uppercased())
                .font(SGTypography.displayTitle)
                .tracking(0.8)
                .foregroundStyle(SGColor.textPrimary)

            Text(definition.subtitle)
                .font(SGTypography.subheadline)
                .foregroundStyle(SGColor.textSecondary)
        }
        .padding(SGSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private var instructionsCard: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: "Step-by-Step Instructions")

            VStack(alignment: .leading, spacing: SGSpacing.small) {
                ForEach(Array(definition.instructions.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: SGSpacing.small) {
                        Text("\(index + 1)")
                            .font(SGTypography.metricValue)
                            .foregroundStyle(SGColor.inkOnPop)
                            .frame(width: 26, height: 26)
                            .background(SGColor.popBlue)
                            .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))

                        Text(line)
                            .font(SGTypography.body)
                            .foregroundStyle(SGColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Rectangle()
                    .fill(SGColor.borderSubtle)
                    .frame(height: 1)
                    .padding(.vertical, 2)

                HStack(alignment: .top, spacing: SGSpacing.xSmall) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(SGColor.inkOnPop)
                        .padding(4)
                        .background(SGColor.popGreen)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("EXPECTED RESULT")
                            .font(SGTypography.metricLabel)
                            .tracking(0.8)
                            .foregroundStyle(SGColor.textSecondary)
                        Text(definition.whatToVerify)
                            .font(SGTypography.caption)
                            .foregroundStyle(SGColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(SGSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private var verdictAndNotesCard: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: "Record Result", trailingText: record.verdict.title)

            VStack(alignment: .leading, spacing: SGSpacing.small) {
                HStack(spacing: SGSpacing.xSmall) {
                    verdictButton(.passed, title: "PASS", icon: "checkmark", accent: SGColor.popGreen)
                    verdictButton(.failed, title: "FAIL", icon: "xmark", accent: SGColor.popRed)
                    verdictButton(.skipped, title: "SKIP", icon: "forward.fill", accent: SGColor.popYellow)
                }

                Text("OBSERVATIONS / NOTES (OPTIONAL)")
                    .font(SGTypography.metricLabel)
                    .tracking(0.8)
                    .foregroundStyle(SGColor.textSecondary)

                TextField(
                    "Record quirk observations, error text, or device notes...",
                    text: Binding(
                        get: { model.record(for: stepID).notes },
                        set: { model.setNotes($0, for: stepID) }
                    ),
                    axis: .vertical
                )
                .font(SGTypography.subheadline)
                .foregroundStyle(SGColor.textPrimary)
                .lineLimit(3...6)
                .padding(SGSpacing.xSmall)
                .background(SGColor.surfaceElevated)
                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private func verdictButton(
        _ verdict: ManualCheckVerdict,
        title: String,
        icon: String,
        accent: Color
    ) -> some View {
        let isSelected = record.verdict == verdict
        return Button {
            model.setVerdict(isSelected ? .pending : verdict, for: stepID)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption.weight(.black))
                Text(title)
                    .font(SGTypography.displayCompact)
                    .tracking(0.8)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(
            BrutalistButtonStyle(
                fill: isSelected ? accent : SGColor.surfaceElevated,
                foreground: isSelected ? SGColor.inkOnPop : SGColor.textPrimary,
                borderWidth: SGBorder.regular,
                shadowOffset: isSelected ? SGShadow.small : 2,
                fullWidth: true,
                showGrain: isSelected
            )
        )
    }

    private func verdictBadge(_ verdict: ManualCheckVerdict) -> some View {
        let color: Color
        switch verdict {
        case .pending: color = SGColor.surfaceElevated
        case .passed: color = SGColor.popGreen
        case .failed: color = SGColor.popRed
        case .skipped: color = SGColor.popYellow
        }
        return SGStatusBadge(
            title: verdict.title,
            color: color,
            isInactive: verdict == .pending
        )
    }
}
#endif
