import SwiftUI

struct SSIDOptionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: TunnelEditorViewModel

    @State private var connectedSSID: String?
    @State private var newSSIDText = ""

    private let options: [OnDemandPolicy.SSIDOptionKind] = [
        .any,
        .only,
        .except
    ]

    private var canAddConnectedSSID: Bool {
        guard let connectedSSID, !connectedSSID.isEmpty else { return false }
        return !viewModel.selectedSSIDs.contains(connectedSSID)
    }

    var body: some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: tr("tunnelOnDemandSSIDViewTitle"),
                enableSwipeBack: true,
                leading: {
                    BrutalistBackButton {
                        dismiss()
                    }
                }
            )

            ScrollView {
                VStack(spacing: SGSpacing.medium) {
                    modeOptionsCard

                    if viewModel.ssidOption != .any {
                        selectedSSIDsCard
                        addSSIDsCard
                    }
                }
                .padding(SGSpacing.medium)
                .padding(.bottom, SGSpacing.xxLarge)
            }
            .background(SGColor.surfacePrimary.ignoresSafeArea())
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            connectedSSID = await TunnelEditorViewModel.fetchConnectedSSID()
        }
        .onDisappear {
            viewModel.normalizeSSIDSettings()
        }
    }

    private var modeOptionsCard: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: "Wi-Fi Matching")

            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.title) { index, option in
                    let isSelected = viewModel.ssidOption == option
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.snappy(duration: 0.2)) {
                            viewModel.ssidOption = option
                        }
                    } label: {
                        HStack(spacing: SGSpacing.small) {
                            Text(option.title)
                                .font(SGTypography.bodyBold)
                                .foregroundStyle(SGColor.textPrimary)
                            Spacer()
                            ZStack {
                                Rectangle()
                                    .fill(isSelected ? SGColor.popYellow : SGColor.surfaceElevated)
                                    .frame(width: 24, height: 24)
                                    .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.black))
                                        .foregroundStyle(SGColor.inkOnPop)
                                }
                            }
                        }
                        .padding(SGSpacing.medium)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < options.count - 1 {
                        Rectangle().fill(SGColor.borderSubtle).frame(height: 1)
                    }
                }
            }
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private var selectedSSIDsCard: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: tr("tunnelOnDemandSectionTitleSelectedSSIDs"))

            VStack(spacing: SGSpacing.xSmall) {
                if viewModel.selectedSSIDs.isEmpty {
                    Text(tr("tunnelOnDemandNoSSIDs"))
                        .font(SGTypography.subheadline)
                        .foregroundStyle(SGColor.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SGSpacing.small)
                } else {
                    ForEach(viewModel.selectedSSIDs.indices, id: \.self) { index in
                        HStack(spacing: SGSpacing.xSmall) {
                            Image(systemName: "wifi")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SGColor.inkOnPop)
                                .frame(width: 28, height: 28)
                                .background(SGColor.popPurple)
                                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))

                            TextField(
                                tr("tunnelOnDemandSSIDTextFieldPlaceholder"),
                                text: Binding(
                                    get: {
                                        index < viewModel.selectedSSIDs.count ? viewModel.selectedSSIDs[index] : ""
                                    },
                                    set: { updated in
                                        if index < viewModel.selectedSSIDs.count {
                                            viewModel.selectedSSIDs[index] = updated
                                        }
                                    }
                                )
                            )
                            .font(SGTypography.monoValue)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, SGSpacing.xSmall)
                            .padding(.vertical, 7)
                            .background(SGColor.surfaceElevated)
                            .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))

                            Button {
                                if index < viewModel.selectedSSIDs.count {
                                    viewModel.selectedSSIDs.remove(at: index)
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.black))
                                    .foregroundStyle(SGColor.pureWhite)
                                    .frame(width: 28, height: 28)
                                    .background(SGColor.popRed)
                                    .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove SSID")
                        }
                    }
                }
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private var addSSIDsCard: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: tr("tunnelOnDemandSectionTitleAddSSIDs"))

            VStack(spacing: SGSpacing.small) {
                if let connectedSSID, canAddConnectedSSID {
                    Button {
                        viewModel.selectedSSIDs.append(connectedSSID)
                    } label: {
                        HStack(spacing: SGSpacing.xSmall) {
                            Image(systemName: "wifi")
                                .font(.subheadline.weight(.bold))
                            Text(tr(format: "tunnelOnDemandAddMessageAddConnectedSSID (%@)", connectedSSID).uppercased())
                                .font(SGTypography.displayCompact)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, SGSpacing.small)
                    }
                    .buttonStyle(
                        BrutalistButtonStyle(
                            fill: SGColor.popPurple,
                            foreground: SGColor.inkOnPop,
                            borderWidth: SGBorder.regular,
                            shadowOffset: SGShadow.small,
                            fullWidth: true
                        )
                    )
                }

                HStack(spacing: SGSpacing.small) {
                    TextField(tr("tunnelOnDemandSSIDTextFieldPlaceholder"), text: $newSSIDText)
                        .font(SGTypography.monoValue)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .padding(.horizontal, SGSpacing.xSmall)
                        .padding(.vertical, 8)
                        .background(SGColor.surfaceElevated)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
                        .onSubmit(appendNewSSID)

                    Button {
                        appendNewSSID()
                    } label: {
                        Text("ADD")
                            .font(SGTypography.displayCompact)
                            .tracking(0.8)
                            .padding(.horizontal, SGSpacing.small)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(
                        BrutalistButtonStyle(
                            fill: SGColor.popYellow,
                            foreground: SGColor.inkOnPop,
                            borderWidth: SGBorder.regular,
                            shadowOffset: SGShadow.small
                        )
                    )
                    .disabled(newSSIDText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private func appendNewSSID() {
        let trimmed = newSSIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !viewModel.selectedSSIDs.contains(trimmed) {
            viewModel.selectedSSIDs.append(trimmed)
        }
        newSSIDText = ""
    }
}
