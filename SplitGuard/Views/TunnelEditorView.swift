import SwiftUI
import UIKit

struct TunnelEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let store: TunnelStore
    let onSaved: ((TunnelContainer) -> Void)?

    @State private var viewModel: TunnelEditorViewModel
    @State private var peerPendingDeleteID: UUID?
    @State private var copiedPublicKey = false

    init(store: TunnelStore, tunnel: TunnelContainer? = nil, onSaved: ((TunnelContainer) -> Void)? = nil) {
        self.store = store
        self.onSaved = onSaved
        _viewModel = State(initialValue: TunnelEditorViewModel(tunnel: tunnel))
    }

    var body: some View {
        NavigationStack {
            Form {
                interfaceNameSection
                interfaceKeysSection
                interfaceNetworkSection
                peersSections
                addPeerSection
                SplitDNSEditorSection(
                    viewModel: viewModel,
                    isTunnelActive: viewModel.existingTunnel.map { store.status(for: $0) == .active } ?? false
                )
                onDemandSection
            }
            .navigationTitle(viewModel.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("actionCancel")) {
                        dismiss()
                    }
                    .disabled(viewModel.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("actionSave")) {
                        viewModel.save(into: store) { savedTunnel in
                            onSaved?(savedTunnel)
                            dismiss()
                        }
                    }
                    .disabled(viewModel.isSaving)
                }
            }
            .alert(
                viewModel.validationAlert?.title ?? "",
                isPresented: Binding(
                    get: { viewModel.validationAlert != nil },
                    set: { isPresented in
                        if !isPresented {
                            viewModel.validationAlert = nil
                        }
                    }
                )
            ) {
                Button(tr("actionOK"), role: .cancel) {
                    viewModel.validationAlert = nil
                }
            } message: {
                Text(viewModel.validationAlert?.message ?? "")
            }
            .confirmationDialog(
                tr("deletePeerConfirmationAlertMessage"),
                isPresented: Binding(
                    get: { peerPendingDeleteID != nil },
                    set: { isPresented in
                        if !isPresented {
                            peerPendingDeleteID = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button(tr("deletePeerConfirmationAlertButtonTitle"), role: .destructive) {
                    if let peerID = peerPendingDeleteID {
                        withAnimation(.snappy(duration: 0.2)) {
                            viewModel.deletePeer(id: peerID)
                        }
                    }
                    peerPendingDeleteID = nil
                }
                Button(tr("actionCancel"), role: .cancel) {
                    peerPendingDeleteID = nil
                }
            }
        }
    }

    private var interfaceNameSection: some View {
        Section(tr("tunnelSectionTitleInterface")) {
            EditorTextRow(
                label: TunnelViewModel.InterfaceField.name.localizedUIString,
                placeholder: tr("tunnelEditPlaceholderTextRequired"),
                text: Binding(
                    get: { viewModel.name },
                    set: { viewModel.updateName($0) }
                ),
                hasError: viewModel.interfaceErrorFields.contains(.name),
                isMonospaced: false,
                keyboardType: .default
            )
        }
    }

    private var interfaceKeysSection: some View {
        Section {
            EditorTextRow(
                label: TunnelViewModel.InterfaceField.privateKey.localizedUIString,
                placeholder: tr("tunnelEditPlaceholderTextRequired"),
                text: Binding(
                    get: { viewModel.privateKey },
                    set: { viewModel.updatePrivateKey($0) }
                ),
                hasError: viewModel.interfaceErrorFields.contains(.privateKey),
                isMonospaced: true,
                keyboardType: .asciiCapable
            )

            publicKeyDisplayRow

            Button {
                viewModel.generateKeyPair()
            } label: {
                Label(tr("tunnelInterfaceGenerateKeypair"), systemImage: "key.fill")
            }
        }
    }

    private var publicKeyDisplayRow: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xxSmall) {
            HStack {
                Text(TunnelViewModel.InterfaceField.publicKey.localizedUIString)
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.textSecondary)
                Spacer()
                if copiedPublicKey {
                    Label("Copied", systemImage: "checkmark")
                        .font(SGTypography.metricLabel)
                        .foregroundStyle(SGColor.accent)
                }
            }

            if viewModel.publicKey.isEmpty {
                Text("Derived from private key")
                    .font(SGTypography.subheadline)
                    .foregroundStyle(SGColor.textTertiary)
            } else {
                Button {
                    UIPasteboard.general.string = viewModel.publicKey
                    copiedPublicKey = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedPublicKey = false
                    }
                } label: {
                    Text(viewModel.publicKey)
                        .font(SGTypography.monoValue)
                        .foregroundStyle(SGColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    private var interfaceNetworkSection: some View {
        Section {
            EditorTextRow(
                label: TunnelViewModel.InterfaceField.addresses.localizedUIString,
                placeholder: tr("tunnelEditPlaceholderTextStronglyRecommended"),
                text: Binding(
                    get: { viewModel.addresses },
                    set: { viewModel.updateAddresses($0) }
                ),
                hasError: viewModel.interfaceErrorFields.contains(.addresses),
                isMonospaced: true,
                keyboardType: .numbersAndPunctuation
            )

            EditorTextRow(
                label: TunnelViewModel.InterfaceField.listenPort.localizedUIString,
                placeholder: tr("tunnelEditPlaceholderTextAutomatic"),
                text: Binding(
                    get: { viewModel.listenPort },
                    set: { viewModel.updateListenPort($0) }
                ),
                hasError: viewModel.interfaceErrorFields.contains(.listenPort),
                isMonospaced: true,
                keyboardType: .numberPad
            )

            EditorTextRow(
                label: TunnelViewModel.InterfaceField.mtu.localizedUIString,
                placeholder: tr("tunnelEditPlaceholderTextAutomatic"),
                text: Binding(
                    get: { viewModel.mtu },
                    set: { viewModel.updateMTU($0) }
                ),
                hasError: viewModel.interfaceErrorFields.contains(.mtu),
                isMonospaced: true,
                keyboardType: .numberPad
            )

            EditorTextRow(
                label: TunnelViewModel.InterfaceField.dns.localizedUIString,
                placeholder: viewModel.shouldStronglyRecommendDNS
                    ? tr("tunnelEditPlaceholderTextStronglyRecommended")
                    : tr("tunnelEditPlaceholderTextOptional"),
                text: Binding(
                    get: { viewModel.dns },
                    set: { viewModel.updateDNS($0) }
                ),
                hasError: viewModel.interfaceErrorFields.contains(.dns),
                isMonospaced: true,
                keyboardType: .numbersAndPunctuation
            )
        }
    }

    private var peersSections: some View {
        ForEach(viewModel.peerItems) { item in
            PeerEditorSection(
                viewModel: viewModel,
                item: item,
                peerCount: viewModel.peerItems.count,
                onRequestDelete: {
                    peerPendingDeleteID = item.id
                }
            )
        }
    }

    private var addPeerSection: some View {
        Section {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    viewModel.addPeer()
                }
            } label: {
                Label(tr("addPeerButtonTitle"), systemImage: "plus.circle")
            }
        }
    }

    private var onDemandSection: some View {
        Section(tr("tunnelSectionTitleOnDemand")) {
            Toggle(tr("tunnelOnDemandCellular"), isOn: $viewModel.isCellularOnDemandEnabled)
            Toggle(tr("tunnelOnDemandWiFi"), isOn: $viewModel.isWiFiOnDemandEnabled)

            if viewModel.isWiFiOnDemandEnabled {
                NavigationLink {
                    SSIDOptionEditorView(viewModel: viewModel)
                } label: {
                    LabeledContent(tr("tunnelOnDemandSSIDsKey"), value: viewModel.onDemandSSIDSummary)
                }
            }
        }
    }
}

private struct PeerEditorSection: View {
    let viewModel: TunnelEditorViewModel
    let item: EditablePeerItem
    let peerCount: Int
    let onRequestDelete: () -> Void

    private var sectionTitle: String {
        peerCount > 1 ? "\(tr("tunnelSectionTitlePeer")) \(item.index + 1)" : tr("tunnelSectionTitlePeer")
    }

    var body: some View {
        Section(sectionTitle) {
            peerFieldRow(.publicKey, placeholder: tr("tunnelEditPlaceholderTextRequired"), keyboard: .asciiCapable)
            peerFieldRow(.preSharedKey, placeholder: tr("tunnelEditPlaceholderTextOptional"), keyboard: .asciiCapable)
            peerFieldRow(.endpoint, placeholder: tr("tunnelEditPlaceholderTextOptional"), keyboard: .asciiCapable)
            peerFieldRow(.allowedIPs, placeholder: tr("tunnelEditPlaceholderTextOptional"), keyboard: .numbersAndPunctuation)

            if viewModel.shouldAllowExcludePrivateIPs(for: item.id) {
                Toggle(
                    tr("tunnelPeerExcludePrivateIPs"),
                    isOn: Binding(
                        get: { viewModel.excludePrivateIPsValue(for: item.id) },
                        set: { viewModel.setExcludePrivateIPs($0, for: item.id) }
                    )
                )
            }

            peerFieldRow(.persistentKeepAlive, placeholder: tr("tunnelEditPlaceholderTextOff"), keyboard: .numberPad)

            Button(role: .destructive, action: onRequestDelete) {
                Label(tr("deletePeerButtonTitle"), systemImage: "trash")
            }
        }
    }

    private func peerFieldRow(
        _ field: TunnelViewModel.PeerField,
        placeholder: String,
        keyboard: UIKeyboardType
    ) -> some View {
        EditorTextRow(
            label: field.localizedUIString,
            placeholder: placeholder,
            text: Binding(
                get: { viewModel.peerValue(for: item.id, field: field) },
                set: { viewModel.updatePeerValue($0, for: item.id, field: field) }
            ),
            hasError: viewModel.hasPeerError(for: item.id, field: field),
            isMonospaced: true,
            keyboardType: keyboard
        )
    }
}

private struct EditorTextRow: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let hasError: Bool
    let isMonospaced: Bool
    let keyboardType: UIKeyboardType

    var body: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xxSmall) {
            Text(label)
                .font(SGTypography.caption)
                .foregroundStyle(hasError ? SGColor.statusError : SGColor.textSecondary)

            TextField(placeholder, text: $text)
                .font(isMonospaced ? SGTypography.monoValue : SGTypography.body)
                .foregroundStyle(hasError ? SGColor.statusError : SGColor.textPrimary)
                .keyboardType(keyboardType)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.vertical, 2)
    }
}
