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

    private var isTunnelActive: Bool {
        viewModel.existingTunnel.map { store.status(for: $0) == .active } ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            sectionPicker

            ScrollView {
                VStack(spacing: SGSpacing.medium) {
                    sectionContent
                }
                .padding(.horizontal, SGSpacing.medium)
                .padding(.top, SGSpacing.medium)
                .padding(.bottom, SGSpacing.xxLarge)
            }
            .id(viewModel.selectedSection)
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
            Button(L10n.tr("action.ok", defaultValue: "OK"), role: .cancel) {
                viewModel.validationAlert = nil
            }
        } message: {
            Text(viewModel.validationAlert?.message ?? "")
        }
        .confirmationDialog(
            L10n.tr("tunnel.peer.delete.confirm", defaultValue: "Delete this peer?"),
            isPresented: Binding(
                get: { peerPendingDeleteID != nil },
                set: { if !$0 { peerPendingDeleteID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("action.delete", defaultValue: "Delete"), role: .destructive) {
                if let peerID = peerPendingDeleteID {
                    withAnimation(.snappy(duration: 0.2)) {
                        viewModel.deletePeer(id: peerID)
                    }
                }
                peerPendingDeleteID = nil
            }
            Button(L10n.tr("action.cancel", defaultValue: "Cancel"), role: .cancel) {
                peerPendingDeleteID = nil
            }
        }
    }

    private var editorHeader: some View {
        BrutalistHeaderBar(
            title: viewModel.navigationTitle,
            leading: {
                BrutalistHeaderButton(
                    title: L10n.tr("action.cancel", defaultValue: "Cancel"),
                    fill: SGColor.surfaceCard,
                    foreground: SGColor.textPrimary
                ) {
                    dismiss()
                }
                .disabled(viewModel.isSaving)
            },
            trailing: {
                BrutalistHeaderButton(
                    title: L10n.tr("action.save", defaultValue: "Save"),
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

    private var sectionPicker: some View {
        VStack(spacing: 0) {
            BrutalistSegmentedControl(
                selection: Binding(
                    get: { viewModel.selectedSection },
                    set: { newValue in
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                        viewModel.selectedSection = newValue
                    }
                ),
                options: TunnelEditorSection.allCases.map { section in
                    .init(
                        value: section,
                        title: sectionTitle(section),
                        accent: sectionAccent(section),
                        showsAlert: viewModel.hasErrors(in: section)
                    )
                }
            )
            .padding(.horizontal, SGSpacing.medium)
            .padding(.top, SGSpacing.small)
            .padding(.bottom, SGSpacing.small + 3)

            Rectangle()
                .fill(SGColor.borderInk)
                .frame(height: SGBorder.thin)
        }
        .background(SGColor.surfacePrimary)
    }

    private func sectionTitle(_ section: TunnelEditorSection) -> String {
        if section == .peers, viewModel.peers.count > 1 {
            return "\(section.title) \(viewModel.peers.count)"
        }
        return section.title
    }

    private func sectionAccent(_ section: TunnelEditorSection) -> Color {
        switch section {
        case .interface:
            return SGColor.popYellow
        case .peers:
            return SGColor.popPurple
        case .dns:
            return SGColor.popBlue
        case .behavior:
            return SGColor.popGreen
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch viewModel.selectedSection {
        case .interface:
            InterfaceEditorCard(viewModel: viewModel)
        case .peers:
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
        case .dns:
            SplitDNSEditorSection(viewModel: viewModel, isTunnelActive: isTunnelActive)
        case .behavior:
            OnDemandEditorCard(viewModel: viewModel) {
                showSSIDEditor = true
            }
            KillSwitchEditorCard(viewModel: viewModel)
            HealthAlertsEditorCard(viewModel: viewModel)
        }
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
                Text(L10n.tr("tunnel.peer.add", defaultValue: "Add peer").uppercased())
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
