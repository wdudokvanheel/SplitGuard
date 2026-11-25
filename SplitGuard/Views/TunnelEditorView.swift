import SwiftUI
import UIKit

struct TunnelEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let store: TunnelStore
    let onSaved: ((Tunnel) -> Void)?

    @State private var viewModel: TunnelEditorViewModel
    @State private var peerPendingDeleteID: UUID?
    @State private var showSSIDEditor = false

    init(store: TunnelStore, tunnel: Tunnel? = nil, onSaved: ((Tunnel) -> Void)? = nil) {
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
                    ForEach(Array(viewModel.peers.enumerated()), id: \.element.id) { index, peer in
                        PeerEditorCard(
                            viewModel: viewModel,
                            peerID: peer.id,
                            peerIndex: index,
                            peerCount: viewModel.peers.count,
                            onRequestDelete: { peerPendingDeleteID = peer.id }
                        )
                    }
                    addPeerButton
                    OnDemandEditorCard(viewModel: viewModel) {
                        showSSIDEditor = true
                    }
                    KillSwitchEditorCard(viewModel: viewModel)
                    HealthAlertsEditorCard(viewModel: viewModel)
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
            Button(String(localized: "action.ok", defaultValue: "OK"), role: .cancel) {
                viewModel.validationAlert = nil
            }
        } message: {
            Text(viewModel.validationAlert?.message ?? "")
        }
        .confirmationDialog(
            String(localized: "tunnel.peer.delete.confirm", defaultValue: "Delete this peer?"),
            isPresented: Binding(
                get: { peerPendingDeleteID != nil },
                set: { if !$0 { peerPendingDeleteID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "action.delete", defaultValue: "Delete"), role: .destructive) {
                if let peerID = peerPendingDeleteID {
                    withAnimation(.snappy(duration: 0.2)) {
                        viewModel.deletePeer(id: peerID)
                    }
                }
                peerPendingDeleteID = nil
            }
            Button(String(localized: "action.cancel", defaultValue: "Cancel"), role: .cancel) {
                peerPendingDeleteID = nil
            }
        }
    }

    private var editorHeader: some View {
        BrutalistHeaderBar(
            title: viewModel.navigationTitle,
            leading: {
                BrutalistHeaderButton(
                    title: String(localized: "action.cancel", defaultValue: "Cancel"),
                    fill: SGColor.surfaceCard,
                    foreground: SGColor.textPrimary
                ) {
                    dismiss()
                }
                .disabled(viewModel.isSaving)
            },
            trailing: {
                BrutalistHeaderButton(
                    title: String(localized: "action.save", defaultValue: "Save"),
                    fill: SGColor.popGreen,
                    foreground: SGColor.inkOnPop,
                    showGrain: true
                ) {
                    Task {
                        if let savedTunnel = await viewModel.save(into: store) {
                            if let onSaved {
                                onSaved(savedTunnel)
                            } else {
                                dismiss()
                            }
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
                Text(String(localized: "tunnel.peer.add", defaultValue: "Add peer").uppercased())
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
