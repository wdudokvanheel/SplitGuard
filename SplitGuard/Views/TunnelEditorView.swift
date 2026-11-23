import SwiftUI
import UIKit

struct TunnelEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let store: TunnelStore
    let onSaved: ((TunnelContainer) -> Void)?

    @State private var viewModel: TunnelEditorViewModel
    @State private var peerPendingDeleteID: UUID?
    @State private var showSSIDEditor = false

    init(store: TunnelStore, tunnel: TunnelContainer? = nil, onSaved: ((TunnelContainer) -> Void)? = nil) {
        self.store = store
        self.onSaved = onSaved
        _viewModel = State(initialValue: TunnelEditorViewModel(tunnel: tunnel))
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader

            ScrollView {
                VStack(spacing: SGSpacing.medium) {
                    InterfaceEditorCard(viewModel: viewModel)
                    SplitDNSEditorSection(
                        viewModel: viewModel,
                        isTunnelActive: viewModel.existingTunnel.map { store.status(for: $0) == .active } ?? false
                    )
                    ForEach(viewModel.peerItems) { item in
                        PeerEditorCard(
                            viewModel: viewModel,
                            item: item,
                            peerCount: viewModel.peerItems.count,
                            onRequestDelete: { peerPendingDeleteID = item.id }
                        )
                    }
                    addPeerButton
                    OnDemandEditorCard(viewModel: viewModel) {
                        showSSIDEditor = true
                    }
                }
                .padding(.horizontal, SGSpacing.medium)
                .padding(.top, SGSpacing.medium)
                .padding(.bottom, SGSpacing.xxLarge)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(SGColor.surfacePrimary.ignoresSafeArea())
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showSSIDEditor) {
            SSIDOptionEditorView(viewModel: viewModel)
        }
        .alert(
            viewModel.validationAlert?.title ?? "",
            isPresented: Binding(
                get: { viewModel.validationAlert != nil },
                set: { if !$0 { viewModel.validationAlert = nil } }
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
                set: { if !$0 { peerPendingDeleteID = nil } }
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

    private var editorHeader: some View {
        BrutalistHeaderBar(
            title: viewModel.navigationTitle,
            leading: {
                BrutalistHeaderButton(
                    title: tr("actionCancel"),
                    fill: SGColor.surfaceCard,
                    foreground: SGColor.textPrimary
                ) {
                    dismiss()
                }
                .disabled(viewModel.isSaving)
            },
            trailing: {
                BrutalistHeaderButton(
                    title: tr("actionSave"),
                    fill: SGColor.popGreen,
                    foreground: SGColor.inkOnPop,
                    showGrain: true
                ) {
                    viewModel.save(into: store) { savedTunnel in
                        if let onSaved {
                            onSaved(savedTunnel)
                        } else {
                            dismiss()
                        }
                    }
                }
                .disabled(viewModel.isSaving)
            }
        )
    }

    private var addPeerButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                viewModel.addPeer()
            }
        } label: {
            HStack(spacing: SGSpacing.xSmall) {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.black))
                Text(tr("addPeerButtonTitle").uppercased())
                    .font(SGTypography.displayCompact)
                    .tracking(0.8)
            }
            .padding(.vertical, 12)
        }
        .buttonStyle(
            BrutalistButtonStyle(
                fill: SGColor.popPurple,
                foreground: SGColor.inkOnPop,
                borderWidth: SGBorder.regular,
                shadowOffset: SGShadow.small,
                fullWidth: true,
                showGrain: true
            )
        )
    }
}
