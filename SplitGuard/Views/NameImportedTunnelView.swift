// SPDX-License-Identifier: MIT

import SplitGuardCore
import SwiftUI

struct NameImportedTunnelView: View {
    let promptTitle: String
    @Binding var tunnelName: String
    let profile: TunnelProfile
    var isSaving: Bool = false
    let onCancel: () -> Void
    let onSave: () -> Void

    @FocusState private var isNameFieldFocused: Bool

    private var canSave: Bool {
        !isSaving && !tunnelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: "Name Tunnel",
                leading: {
                    BrutalistHeaderButton(
                        title: String(localized: "action.cancel", defaultValue: "Cancel"),
                        fill: SGColor.surfaceCard,
                        foreground: SGColor.textPrimary,
                        action: onCancel
                    )
                    .disabled(isSaving)
                },
                trailing: {
                    BrutalistHeaderButton(
                        title: String(localized: "action.save", defaultValue: "Save"),
                        fill: SGColor.popGreen,
                        foreground: SGColor.inkOnPop,
                        showGrain: true,
                        action: onSave
                    )
                    .disabled(!canSave)
                }
            )

            ScrollView {
                VStack(spacing: SGSpacing.medium) {
                    VStack(spacing: 0) {
                        BrutalistSectionBar(title: promptTitle)
                        TextField("e.g. Home VPN", text: $tunnelName)
                            .font(SGTypography.body)
                            .foregroundStyle(SGColor.textPrimary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .focused($isNameFieldFocused)
                            .onSubmit {
                                if canSave {
                                    onSave()
                                }
                            }
                            .padding(.horizontal, SGSpacing.xSmall)
                            .padding(.vertical, 10)
                            .background(SGColor.surfaceElevated)
                            .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
                            .padding(SGSpacing.medium)
                            .background(SGColor.surfaceCard)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
                    .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)

                    if hasDetectedDetails {
                        VStack(spacing: 0) {
                            BrutalistSectionBar(title: "Detected Configuration")
                            VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
                                if let endpoint = profile.peers.first?.endpoint?.description {
                                    detectedInfoRow(label: "ENDPOINT", value: endpoint)
                                }
                                if !profile.interface.dnsServers.isEmpty {
                                    detectedInfoRow(
                                        label: "DNS",
                                        value: profile.interface.dnsServers.map(\.description).joined(separator: ", ")
                                    )
                                }
                                if profile.splitDNS.mode == .onlyDomains,
                                   !profile.splitDNS.normalizedDomainNames.isEmpty {
                                    detectedInfoRow(
                                        label: "SPLIT DNS",
                                        value: profile.splitDNS.normalizedDomainNames.joined(separator: ", ")
                                    )
                                }
                            }
                            .padding(SGSpacing.medium)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(SGColor.surfaceCard)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
                        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
                    }
                }
                .padding(SGSpacing.medium)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(SGColor.surfacePrimary.ignoresSafeArea())
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .onAppear {
            isNameFieldFocused = true
        }
    }

    private var hasDetectedDetails: Bool {
        profile.peers.first?.endpoint != nil ||
            !profile.interface.dnsServers.isEmpty ||
            (profile.splitDNS.mode == .onlyDomains && !profile.splitDNS.normalizedDomainNames.isEmpty)
    }

    private func detectedInfoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(SGTypography.metricLabel)
                .foregroundStyle(SGColor.textSecondary)
            Spacer()
            Text(value)
                .font(SGTypography.monoCompact.weight(.semibold))
                .foregroundStyle(SGColor.textPrimary)
        }
    }
}

struct NameImportedTunnelRouteView: View {
    let store: TunnelStore
    let profile: TunnelProfile
    let onCancel: () -> Void
    let onSaved: () -> Void

    @State private var tunnelName: String
    @State private var isSaving = false

    init(
        store: TunnelStore,
        profile: TunnelProfile,
        onCancel: @escaping () -> Void,
        onSaved: @escaping () -> Void
    ) {
        self.store = store
        self.profile = profile
        self.onCancel = onCancel
        self.onSaved = onSaved
        _tunnelName = State(initialValue: profile.name)
    }

    var body: some View {
        NameImportedTunnelView(
            promptTitle: "Please name the imported tunnel",
            tunnelName: $tunnelName,
            profile: profile,
            isSaving: isSaving,
            onCancel: onCancel,
            onSave: saveTunnel
        )
        .toolbar(.hidden, for: .navigationBar)
    }

    private func saveTunnel() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            let succeeded = await store.addProfile(profile, named: tunnelName)
            isSaving = false
            if succeeded {
                onSaved()
            }
        }
    }
}
