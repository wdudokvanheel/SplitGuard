import SwiftUI

struct SSIDOptionEditorView: View {
    @Bindable var viewModel: TunnelEditorViewModel

    @State private var connectedSSID: String?
    @State private var newSSIDText = ""

    private let options: [ActivateOnDemandViewModel.OnDemandSSIDOption] = [
        .anySSID,
        .onlySpecificSSIDs,
        .exceptSpecificSSIDs
    ]

    private var canAddConnectedSSID: Bool {
        guard let connectedSSID, !connectedSSID.isEmpty else { return false }
        return !viewModel.selectedSSIDs.contains(connectedSSID)
    }

    var body: some View {
        Form {
            Section {
                ForEach(options, id: \.localizedUIString) { option in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            viewModel.ssidOption = option
                        }
                    } label: {
                        HStack {
                            Text(option.localizedUIString)
                                .foregroundStyle(SGColor.textPrimary)
                            Spacer()
                            if viewModel.ssidOption == option {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(SGColor.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if viewModel.ssidOption != .anySSID {
                selectedSSIDsSection
                addSSIDsSection
            }
        }
        .navigationTitle(tr("tunnelOnDemandSSIDViewTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            connectedSSID = await TunnelEditorViewModel.fetchConnectedSSID()
        }
        .onDisappear {
            viewModel.normalizeSSIDSettings()
        }
    }

    private var selectedSSIDsSection: some View {
        Section(tr("tunnelOnDemandSectionTitleSelectedSSIDs")) {
            if viewModel.selectedSSIDs.isEmpty {
                Text(tr("tunnelOnDemandNoSSIDs"))
                    .foregroundStyle(SGColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(viewModel.selectedSSIDs.indices, id: \.self) { index in
                    HStack(spacing: SGSpacing.xSmall) {
                        Image(systemName: "wifi")
                            .foregroundStyle(SGColor.textSecondary)
                            .font(.subheadline)
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
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    }
                }
                .onDelete { offsets in
                    viewModel.selectedSSIDs.remove(atOffsets: offsets)
                }
            }
        }
    }

    private var addSSIDsSection: some View {
        Section(tr("tunnelOnDemandSectionTitleAddSSIDs")) {
            if let connectedSSID, canAddConnectedSSID {
                Button {
                    viewModel.selectedSSIDs.append(connectedSSID)
                } label: {
                    Label(
                        tr(format: "tunnelOnDemandAddMessageAddConnectedSSID (%@)", connectedSSID),
                        systemImage: "wifi.circle.fill"
                    )
                }
            }

            HStack(spacing: SGSpacing.xSmall) {
                TextField(tr("tunnelOnDemandSSIDTextFieldPlaceholder"), text: $newSSIDText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(appendNewSSID)

                Button(tr("tunnelOnDemandAddMessageAddNewSSID")) {
                    appendNewSSID()
                }
                .disabled(newSSIDText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
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
