import SwiftUI
import UIKit

struct PasteConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: TunnelStore
    var onImported: (() -> Void)?

    @State private var tunnelName = ""
    @State private var configText = ""

    private var canImport: Bool {
        !tunnelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !configText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: L10n.tr("pasteConfig.title", defaultValue: "Paste Config"),
                leading: {
                    BrutalistHeaderButton(
                        title: L10n.tr("action.cancel", defaultValue: "Cancel"),
                        fill: SGColor.surfaceCard,
                        foreground: SGColor.textPrimary
                    ) {
                        dismiss()
                    }
                },
                trailing: {
                    BrutalistHeaderButton(
                        title: L10n.tr("pasteConfig.import", defaultValue: "Import"),
                        fill: SGColor.popGreen,
                        foreground: SGColor.inkOnPop,
                        showGrain: true
                    ) {
                        Task {
                            let succeeded = await store.importConfigText(configText, named: tunnelName)
                            if succeeded {
                                if let onImported {
                                    onImported()
                                } else {
                                    dismiss()
                                }
                            }
                        }
                    }
                    .disabled(!canImport)
                }
            )

            ScrollView {
                VStack(spacing: SGSpacing.medium) {
                    VStack(spacing: 0) {
                        BrutalistSectionBar(title: L10n.tr("pasteConfig.tunnelName", defaultValue: "Tunnel Name"))
                        TextField(
                            L10n.tr("pasteConfig.tunnelNamePlaceholder", defaultValue: "e.g. Home VPN"),
                            text: $tunnelName
                        )
                            .font(SGTypography.body)
                            .foregroundStyle(SGColor.textPrimary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, SGSpacing.xSmall)
                            .padding(.vertical, 10)
                            .background(SGColor.surfaceElevated)
                            .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
                            .padding(SGSpacing.medium)
                            .background(SGColor.surfaceCard)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
                    .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)

                    VStack(spacing: 0) {
                        BrutalistSectionBar(
                            title: L10n.tr("pasteConfig.configSection", defaultValue: "Configuration (.conf)")
                        )

                        VStack(spacing: SGSpacing.small) {
                            Button {
                                if let clipboard = UIPasteboard.general.string {
                                    configText = clipboard
                                }
                            } label: {
                                HStack(spacing: SGSpacing.xSmall) {
                                    Image(systemName: "doc.on.clipboard.fill")
                                        .font(.subheadline.weight(.bold))
                                    Text(
                                        L10n.tr(
                                            "pasteConfig.pasteFromClipboard",
                                            defaultValue: "Paste from clipboard"
                                        ).uppercased()
                                    )
                                        .font(SGTypography.displayCompact)
                                        .tracking(0.8)
                                }
                                .padding(.vertical, 10)
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

                            TextEditor(text: $configText)
                                .font(SGTypography.monoCompact)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 220)
                                .padding(SGSpacing.xSmall)
                                .background(SGColor.surfaceElevated)
                                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        .padding(SGSpacing.medium)
                        .background(SGColor.surfaceCard)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
                    .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
                }
                .padding(SGSpacing.medium)
                .padding(.bottom, SGSpacing.xxLarge)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(SGColor.surfacePrimary.ignoresSafeArea())
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}
