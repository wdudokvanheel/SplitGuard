import SwiftUI
import UIKit

struct InterfaceEditorCard: View {
    @Bindable var viewModel: TunnelEditorViewModel
    @State private var copiedPublicKey = false
    @State private var showsAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: L10n.tr("tunnel.section.interface", defaultValue: "Interface"))

            VStack(alignment: .leading, spacing: SGSpacing.small) {
                EditorTextRow(
                    label: InterfaceField.name.localizedTitle,
                    placeholder: L10n.tr("tunnel.editor.placeholder.required", defaultValue: "Required"),
                    text: Binding(get: { viewModel.name }, set: { viewModel.updateName($0) }),
                    hasError: viewModel.interfaceErrorFields.contains(.name),
                    isMonospaced: false,
                    keyboardType: .default
                )

                Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                EditorTextRow(
                    label: InterfaceField.privateKey.localizedTitle,
                    placeholder: L10n.tr("tunnel.editor.placeholder.required", defaultValue: "Required"),
                    text: Binding(get: { viewModel.privateKey }, set: { viewModel.updatePrivateKey($0) }),
                    hasError: viewModel.interfaceErrorFields.contains(.privateKey),
                    isMonospaced: true,
                    keyboardType: .asciiCapable
                ) {
                    generateKeyPairButton
                }

                publicKeyDisplayRow

                Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                EditorTextRow(
                    label: InterfaceField.addresses.localizedTitle,
                    placeholder: L10n.tr(
                        "tunnel.editor.placeholder.stronglyRecommended",
                        defaultValue: "Strongly recommended"
                    ),
                    text: Binding(get: { viewModel.addresses }, set: { viewModel.updateAddresses($0) }),
                    hasError: viewModel.interfaceErrorFields.contains(.addresses),
                    isMonospaced: true,
                    keyboardType: .numbersAndPunctuation
                )

                Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                BrutalistDisclosure(
                    title: L10n.tr("tunnel.editor.advanced", defaultValue: "Advanced"),
                    summary: advancedSummary,
                    isExpanded: $showsAdvanced
                ) {
                    EditorTextRow(
                        label: InterfaceField.listenPort.localizedTitle,
                        placeholder: L10n.tr("tunnel.editor.placeholder.automatic", defaultValue: "Automatic"),
                        text: Binding(get: { viewModel.listenPort }, set: { viewModel.updateListenPort($0) }),
                        hasError: viewModel.interfaceErrorFields.contains(.listenPort),
                        isMonospaced: true,
                        keyboardType: .numberPad
                    )

                    EditorTextRow(
                        label: InterfaceField.mtu.localizedTitle,
                        placeholder: L10n.tr("tunnel.editor.placeholder.automatic", defaultValue: "Automatic"),
                        text: Binding(get: { viewModel.mtu }, set: { viewModel.updateMTU($0) }),
                        hasError: viewModel.interfaceErrorFields.contains(.mtu),
                        isMonospaced: true,
                        keyboardType: .numberPad
                    )
                }
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
        .onAppear {
            showsAdvanced = viewModel.hasAdvancedInterfaceValues
        }
        .onChange(of: viewModel.interfaceErrorFields) { _, fields in
            if !fields.isDisjoint(with: [.listenPort, .mtu]) {
                showsAdvanced = true
            }
        }
    }

    private var advancedSummary: String {
        var parts: [String] = []
        if !viewModel.listenPort.isEmpty {
            parts.append(
                L10n.tr("tunnel.editor.advanced.port", defaultValue: "Port \(viewModel.listenPort)")
            )
        }
        if !viewModel.mtu.isEmpty {
            parts.append("MTU \(viewModel.mtu)")
        }
        return parts.isEmpty
            ? L10n.tr("tunnel.editor.advanced.interfaceSummary", defaultValue: "Listen port, MTU")
            : parts.joined(separator: " · ")
    }

    private var generateKeyPairButton: some View {
        Button {
            viewModel.generateKeyPair()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "key.fill")
                    .font(.system(size: 10, weight: .black))
                Text(L10n.tr("tunnel.interface.generateKeypair", defaultValue: "Generate keypair").uppercased())
                    .font(SGTypography.metricLabel)
                    .tracking(0.6)
            }
            .padding(.horizontal, SGSpacing.xSmall)
            .padding(.vertical, 4)
        }
        .buttonStyle(
            BrutalistButtonStyle(
                fill: SGColor.popYellow,
                foreground: SGColor.inkOnPop,
                borderWidth: SGBorder.thin,
                shadowOffset: 2
            )
        )
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
                    Text(L10n.tr("common.copied", defaultValue: "Copied").uppercased())
                        .font(SGTypography.metricLabel)
                        .foregroundStyle(SGColor.inkOnPop)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SGColor.popGreen)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
                }
            }

            if viewModel.publicKey.isEmpty {
                Text(L10n.tr("tunnel.interface.derivedFromPrivateKey", defaultValue: "Derived from private key"))
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

    @State private var showsAdvanced = false

    private var sectionTitle: String {
        if peerCount > 1 {
            let number = peerIndex + 1
            return L10n.tr("tunnel.section.peerNumbered", defaultValue: "Peer \(number)")
        }
        return L10n.tr("tunnel.section.peer", defaultValue: "Peer")
    }

    var body: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: sectionTitle)

            VStack(alignment: .leading, spacing: SGSpacing.small) {
                peerFieldRow(
                    .publicKey,
                    placeholder: L10n.tr("tunnel.editor.placeholder.required", defaultValue: "Required"),
                    keyboard: .asciiCapable
                )
                peerFieldRow(
                    .endpoint,
                    placeholder: L10n.tr("tunnel.editor.placeholder.optional", defaultValue: "Optional"),
                    keyboard: .asciiCapable
                )
                peerFieldRow(
                    .allowedIPs,
                    placeholder: L10n.tr("tunnel.editor.placeholder.optional", defaultValue: "Optional"),
                    keyboard: .numbersAndPunctuation
                )

                if viewModel.shouldAllowExcludePrivateIPs(for: peerID) {
                    BrutalistFormToggleRow(
                        title: L10n.tr("tunnel.peer.excludePrivateIPs", defaultValue: "Exclude private IPs"),
                        isOn: Binding(
                            get: { viewModel.excludePrivateIPsValue(for: peerID) },
                            set: { viewModel.setExcludePrivateIPs($0, for: peerID) }
                        ),
                        activeTint: SGColor.popGreen
                    )
                }

                Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                BrutalistDisclosure(
                    title: L10n.tr("tunnel.editor.advanced", defaultValue: "Advanced"),
                    summary: advancedSummary,
                    isExpanded: $showsAdvanced
                ) {
                    peerFieldRow(
                        .presharedKey,
                        placeholder: L10n.tr("tunnel.editor.placeholder.optional", defaultValue: "Optional"),
                        keyboard: .asciiCapable
                    )
                    peerFieldRow(
                        .persistentKeepalive,
                        placeholder: L10n.tr("tunnel.editor.placeholder.off", defaultValue: "Off"),
                        keyboard: .numberPad
                    )
                }

                Button(action: onRequestDelete) {
                    HStack(spacing: SGSpacing.xSmall) {
                        Image(systemName: "trash.fill")
                            .font(.caption.weight(.bold))
                        Text(L10n.tr("tunnel.peer.delete", defaultValue: "Delete peer").uppercased())
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
        .onAppear {
            showsAdvanced = viewModel.hasAdvancedPeerValues(for: peerID)
        }
        .onChange(of: hasAdvancedErrors) { _, hasErrors in
            if hasErrors {
                showsAdvanced = true
            }
        }
    }

    private var hasAdvancedErrors: Bool {
        viewModel.hasPeerError(for: peerID, field: .presharedKey)
            || viewModel.hasPeerError(for: peerID, field: .persistentKeepalive)
    }

    private var advancedSummary: String {
        var parts: [String] = []
        if !viewModel.peerValue(for: peerID, field: .presharedKey).isEmpty {
            parts.append(L10n.tr("tunnel.editor.advanced.pskSet", defaultValue: "PSK set"))
        }
        let keepalive = viewModel.peerValue(for: peerID, field: .persistentKeepalive)
        if !keepalive.isEmpty {
            parts.append(L10n.tr("tunnel.editor.advanced.keepalive", defaultValue: "Keepalive \(keepalive)s"))
        }
        return parts.isEmpty
            ? L10n.tr("tunnel.editor.advanced.peerSummary", defaultValue: "Preshared key, keepalive")
            : parts.joined(separator: " · ")
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
            BrutalistSectionBar(title: L10n.tr("tunnel.section.onDemand", defaultValue: "On-Demand Activation"))

            VStack(spacing: SGSpacing.small) {
                BrutalistFormToggleRow(
                    title: L10n.tr("tunnel.onDemand.cellular", defaultValue: "Cellular"),
                    isOn: $viewModel.isCellularOnDemandEnabled,
                    activeTint: SGColor.popYellow
                )

                Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                BrutalistFormToggleRow(
                    title: L10n.tr("tunnel.onDemand.wifi", defaultValue: "Wi-Fi"),
                    isOn: $viewModel.isWiFiOnDemandEnabled,
                    activeTint: SGColor.popYellow
                )

                if viewModel.isWiFiOnDemandEnabled {
                    Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                    Button(action: onEditSSIDs) {
                        HStack(spacing: SGSpacing.small) {
                            Text(L10n.tr("tunnel.onDemand.ssids", defaultValue: "SSIDs").uppercased())
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
