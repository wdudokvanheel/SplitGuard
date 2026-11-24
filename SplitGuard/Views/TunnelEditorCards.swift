import SwiftUI
import UIKit

struct InterfaceEditorCard: View {
    @Bindable var viewModel: TunnelEditorViewModel
    @State private var copiedPublicKey = false

    var body: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: tr("tunnelSectionTitleInterface"))

            VStack(alignment: .leading, spacing: SGSpacing.small) {
                EditorTextRow(
                    label: InterfaceField.name.localizedTitle,
                    placeholder: tr("tunnelEditPlaceholderTextRequired"),
                    text: Binding(get: { viewModel.name }, set: { viewModel.updateName($0) }),
                    hasError: viewModel.interfaceErrorFields.contains(.name),
                    isMonospaced: false,
                    keyboardType: .default
                )

                Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                EditorTextRow(
                    label: InterfaceField.privateKey.localizedTitle,
                    placeholder: tr("tunnelEditPlaceholderTextRequired"),
                    text: Binding(get: { viewModel.privateKey }, set: { viewModel.updatePrivateKey($0) }),
                    hasError: viewModel.interfaceErrorFields.contains(.privateKey),
                    isMonospaced: true,
                    keyboardType: .asciiCapable
                )

                publicKeyDisplayRow

                Button {
                    viewModel.generateKeyPair()
                } label: {
                    HStack(spacing: SGSpacing.xSmall) {
                        Image(systemName: "key.fill")
                            .font(.subheadline.weight(.bold))
                        Text(tr("tunnelInterfaceGenerateKeypair").uppercased())
                            .font(SGTypography.displayCompact)
                            .tracking(0.8)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, SGSpacing.small)
                }
                .buttonStyle(
                    BrutalistButtonStyle(
                        fill: SGColor.popYellow,
                        foreground: SGColor.inkOnPop,
                        borderWidth: SGBorder.regular,
                        shadowOffset: SGShadow.small,
                        fullWidth: true
                    )
                )

                Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                EditorTextRow(
                    label: InterfaceField.addresses.localizedTitle,
                    placeholder: tr("tunnelEditPlaceholderTextStronglyRecommended"),
                    text: Binding(get: { viewModel.addresses }, set: { viewModel.updateAddresses($0) }),
                    hasError: viewModel.interfaceErrorFields.contains(.addresses),
                    isMonospaced: true,
                    keyboardType: .numbersAndPunctuation
                )

                EditorTextRow(
                    label: InterfaceField.listenPort.localizedTitle,
                    placeholder: tr("tunnelEditPlaceholderTextAutomatic"),
                    text: Binding(get: { viewModel.listenPort }, set: { viewModel.updateListenPort($0) }),
                    hasError: viewModel.interfaceErrorFields.contains(.listenPort),
                    isMonospaced: true,
                    keyboardType: .numberPad
                )

                EditorTextRow(
                    label: InterfaceField.mtu.localizedTitle,
                    placeholder: tr("tunnelEditPlaceholderTextAutomatic"),
                    text: Binding(get: { viewModel.mtu }, set: { viewModel.updateMTU($0) }),
                    hasError: viewModel.interfaceErrorFields.contains(.mtu),
                    isMonospaced: true,
                    keyboardType: .numberPad
                )

                EditorTextRow(
                    label: InterfaceField.dns.localizedTitle,
                    placeholder: viewModel.shouldStronglyRecommendDNS
                        ? tr("tunnelEditPlaceholderTextStronglyRecommended")
                        : tr("tunnelEditPlaceholderTextOptional"),
                    text: Binding(get: { viewModel.dns }, set: { viewModel.updateDNS($0) }),
                    hasError: viewModel.interfaceErrorFields.contains(.dns),
                    isMonospaced: true,
                    keyboardType: .numbersAndPunctuation
                )
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private var publicKeyDisplayRow: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xxSmall) {
            HStack {
                Text(InterfaceField.publicKey.localizedTitle.uppercased())
                    .font(SGTypography.metricLabel)
                    .tracking(0.6)
                    .foregroundStyle(SGColor.textSecondary)
                Spacer()
                if copiedPublicKey {
                    Text("COPIED")
                        .font(SGTypography.metricLabel)
                        .foregroundStyle(SGColor.inkOnPop)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SGColor.popGreen)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
                }
            }

            if viewModel.publicKey.isEmpty {
                Text("Derived from private key")
                    .font(SGTypography.subheadline)
                    .foregroundStyle(SGColor.textTertiary)
                    .padding(.vertical, 6)
            } else {
                Button {
                    UIPasteboard.general.string = viewModel.publicKey
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    copiedPublicKey = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedPublicKey = false
                    }
                } label: {
                    HStack(spacing: SGSpacing.xSmall) {
                        Text(viewModel.publicKey)
                            .font(SGTypography.monoCompact)
                            .foregroundStyle(SGColor.textPrimary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "doc.on.doc")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(SGColor.textSecondary)
                    }
                    .padding(SGSpacing.xSmall)
                    .background(SGColor.surfaceElevated)
                    .overlay(Rectangle().strokeBorder(SGColor.borderSubtle, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct PeerEditorCard: View {
    let viewModel: TunnelEditorViewModel
    let peerID: UUID
    let peerIndex: Int
    let peerCount: Int
    let onRequestDelete: () -> Void

    private var sectionTitle: String {
        peerCount > 1 ? "\(tr("tunnelSectionTitlePeer")) \(peerIndex + 1)" : tr("tunnelSectionTitlePeer")
    }

    var body: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: sectionTitle)

            VStack(alignment: .leading, spacing: SGSpacing.small) {
                peerFieldRow(.publicKey, placeholder: tr("tunnelEditPlaceholderTextRequired"), keyboard: .asciiCapable)
                peerFieldRow(.presharedKey, placeholder: tr("tunnelEditPlaceholderTextOptional"), keyboard: .asciiCapable)
                peerFieldRow(.endpoint, placeholder: tr("tunnelEditPlaceholderTextOptional"), keyboard: .asciiCapable)
                peerFieldRow(.allowedIPs, placeholder: tr("tunnelEditPlaceholderTextOptional"), keyboard: .numbersAndPunctuation)

                if viewModel.shouldAllowExcludePrivateIPs(for: peerID) {
                    BrutalistFormToggleRow(
                        title: tr("tunnelPeerExcludePrivateIPs"),
                        isOn: Binding(
                            get: { viewModel.excludePrivateIPsValue(for: peerID) },
                            set: { viewModel.setExcludePrivateIPs($0, for: peerID) }
                        ),
                        activeTint: SGColor.popGreen
                    )
                }

                peerFieldRow(.persistentKeepalive, placeholder: tr("tunnelEditPlaceholderTextOff"), keyboard: .numberPad)

                Button(action: onRequestDelete) {
                    HStack(spacing: SGSpacing.xSmall) {
                        Image(systemName: "trash.fill")
                            .font(.caption.weight(.bold))
                        Text(tr("deletePeerButtonTitle").uppercased())
                            .font(SGTypography.displayCompact)
                            .tracking(0.8)
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(
                    BrutalistButtonStyle(
                        fill: SGColor.popRed,
                        foreground: SGColor.pureWhite,
                        borderWidth: SGBorder.regular,
                        shadowOffset: SGShadow.small,
                        fullWidth: true
                    )
                )
                .padding(.top, SGSpacing.xxSmall)
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }

    private func peerFieldRow(
        _ field: PeerField,
        placeholder: String,
        keyboard: UIKeyboardType
    ) -> some View {
        EditorTextRow(
            label: field.localizedTitle,
            placeholder: placeholder,
            text: Binding(
                get: { viewModel.peerValue(for: peerID, field: field) },
                set: { viewModel.updatePeerValue($0, for: peerID, field: field) }
            ),
            hasError: viewModel.hasPeerError(for: peerID, field: field),
            isMonospaced: true,
            keyboardType: keyboard
        )
    }
}

struct OnDemandEditorCard: View {
    @Bindable var viewModel: TunnelEditorViewModel
    let onEditSSIDs: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: tr("tunnelSectionTitleOnDemand"))

            VStack(spacing: SGSpacing.small) {
                BrutalistFormToggleRow(
                    title: tr("tunnelOnDemandCellular"),
                    isOn: $viewModel.isCellularOnDemandEnabled,
                    activeTint: SGColor.popYellow
                )

                Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                BrutalistFormToggleRow(
                    title: tr("tunnelOnDemandWiFi"),
                    isOn: $viewModel.isWiFiOnDemandEnabled,
                    activeTint: SGColor.popYellow
                )

                if viewModel.isWiFiOnDemandEnabled {
                    Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                    Button(action: onEditSSIDs) {
                        HStack(spacing: SGSpacing.small) {
                            Text(tr("tunnelOnDemandSSIDsKey").uppercased())
                                .font(SGTypography.metricLabel)
                                .foregroundStyle(SGColor.textSecondary)
                            Spacer()
                            Text(viewModel.onDemandSSIDSummary)
                                .font(SGTypography.subheadline)
                                .foregroundStyle(SGColor.textPrimary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.black))
                                .foregroundStyle(SGColor.textPrimary)
                        }
                        .padding(SGSpacing.small)
                        .background(SGColor.surfaceElevated)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
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
}

struct EditorTextRow: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let hasError: Bool
    let isMonospaced: Bool
    let keyboardType: UIKeyboardType

    var body: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xxSmall) {
            Text(label.uppercased())
                .font(SGTypography.metricLabel)
                .tracking(0.6)
                .foregroundStyle(hasError ? SGColor.statusError : SGColor.textSecondary)

            TextField(placeholder, text: $text)
                .font(isMonospaced ? SGTypography.monoValue : SGTypography.body)
                .foregroundStyle(hasError ? SGColor.statusError : SGColor.textPrimary)
                .keyboardType(keyboardType)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, SGSpacing.xSmall)
                .padding(.vertical, 9)
                .background(SGColor.surfaceElevated)
                .overlay(
                    Rectangle()
                        .strokeBorder(hasError ? SGColor.statusError : SGColor.borderInk, lineWidth: SGBorder.thin)
                )
        }
    }
}
