import SwiftUI
import WireGuardKit

struct FirstRunSplitDNSSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: TunnelStore
    let prompt: SplitDNSSuggestionPrompt

    @State private var domains: [SplitDNSConfiguration.Domain]
    @State private var newDomainInput = ""
    @State private var inputError: String?
    @State private var isSaving = false

    init(store: TunnelStore, prompt: SplitDNSSuggestionPrompt) {
        self.store = store
        self.prompt = prompt
        _domains = State(initialValue: [.init(name: prompt.suggestedDomain)])
    }

    private var previewConfig: SplitDNSConfiguration {
        SplitDNSConfiguration(mode: .onlyDomains, domains: domains)
    }

    private var parsedDNSServers: [DNSServer] {
        prompt.dnsServers.compactMap { DNSServer(from: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: "Split DNS",
                trailing: {
                    BrutalistHeaderButton(
                        title: "Skip",
                        fill: SGColor.surfaceCard,
                        foreground: SGColor.textPrimary
                    ) {
                        store.dismissSplitDNSSuggestion()
                        dismiss()
                    }
                    .disabled(isSaving)
                }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: SGSpacing.medium) {
                    headerBanner
                    domainsCard
                    previewCard
                    actionButtons
                }
                .padding(SGSpacing.medium)
                .padding(.bottom, SGSpacing.large)
            }
            .background(SGColor.surfacePrimary.ignoresSafeArea())
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var headerBanner: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
            HStack(spacing: SGSpacing.xSmall) {
                Image(systemName: "sparkles")
                    .font(.headline.weight(.black))
                Text("SPLIT DNS SUGGESTION")
                    .font(SGTypography.badge)
                    .tracking(1.0)
            }
            .foregroundStyle(SGColor.inkOnPop)

            Text("ROUTE ONLY \(prompt.suggestedDomain.uppercased()) THROUGH VPN DNS?")
                .font(SGTypography.displayTitle)
                .tracking(0.6)
                .foregroundStyle(SGColor.inkOnPop)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "Detected endpoint domain on \"\(prompt.tunnelName)\". " +
                    "Enable Split DNS so private hostnames resolve via your tunnel while all other traffic uses normal DNS."
            )
            .font(SGTypography.subheadline)
            .foregroundStyle(SGColor.inkOnPop.opacity(0.88))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SGSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brutalistCard(fill: SGColor.popPurple, borderWidth: SGBorder.thick, shadowOffset: SGShadow.medium, showGrain: true)
    }

    private var domainsCard: some View {
        VStack(alignment: .leading, spacing: SGSpacing.small) {
            Text("DOMAINS USING VPN DNS")
                .font(SGTypography.displayCompact)
                .tracking(1.0)
                .foregroundStyle(SGColor.textPrimary)

            ForEach(domains) { domain in
                HStack(spacing: SGSpacing.small) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(domain.name)
                            .font(SGTypography.monoValue.weight(.semibold))
                            .foregroundStyle(SGColor.textPrimary)
                        Text("Matches \(domain.name) and *.\(domain.name)")
                            .font(SGTypography.caption)
                            .foregroundStyle(SGColor.textSecondary)
                    }
                    Spacer()
                    if domains.count > 1 {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                domains.removeAll { $0.name == domain.name }
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.black))
                                .foregroundStyle(SGColor.pureWhite)
                                .frame(width: 26, height: 26)
                                .background(SGColor.popRed)
                                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(domain.name)")
                    }
                }
                .padding(SGSpacing.small)
                .background(SGColor.surfaceElevated)
                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
            }

            HStack(spacing: SGSpacing.xSmall) {
                TextField("Add another domain (optional)", text: $newDomainInput)
                    .font(SGTypography.monoValue)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .padding(.horizontal, SGSpacing.small)
                    .padding(.vertical, 10)
                    .background(SGColor.surfaceCard)
                    .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
                    .onChange(of: newDomainInput) { _, _ in
                        inputError = nil
                    }
                    .onSubmit(addDomain)

                Button {
                    addDomain()
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
                .disabled(newDomainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let inputError {
                Label(inputError, systemImage: "exclamationmark.triangle.fill")
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.popRed)
            }
        }
        .padding(SGSpacing.medium)
        .brutalistCard(fill: SGColor.surfaceCard)
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
            SplitDNSRoutingPreviewView(
                splitDNS: previewConfig,
                dnsServers: parsedDNSServers
            )
        }
        .padding(SGSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brutalistCard(fill: SGColor.surfaceElevated, shadowOffset: SGShadow.small)
    }

    private var actionButtons: some View {
        VStack(spacing: SGSpacing.small) {
            Button {
                applyAndDismiss()
            } label: {
                HStack(spacing: SGSpacing.xSmall) {
                    if isSaving {
                        ProgressView()
                            .tint(SGColor.inkOnPop)
                    } else {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.headline.weight(.bold))
                    }
                    Text("ENABLE SPLIT DNS")
                        .font(SGTypography.displayButton)
                        .tracking(1.0)
                }
                .padding(.vertical, 14)
            }
            .buttonStyle(
                BrutalistButtonStyle(
                    fill: SGColor.popGreen,
                    foreground: SGColor.inkOnPop,
                    borderWidth: SGBorder.regular,
                    shadowOffset: SGShadow.medium,
                    fullWidth: true,
                    showGrain: true
                )
            )
            .disabled(domains.isEmpty || isSaving)

            Button {
                store.dismissSplitDNSSuggestion()
                dismiss()
            } label: {
                Text("KEEP ALL DOMAINS (STANDARD)")
                    .font(SGTypography.displayCompact)
                    .tracking(0.8)
                    .padding(.vertical, 12)
            }
            .buttonStyle(
                BrutalistButtonStyle(
                    fill: SGColor.surfaceCard,
                    foreground: SGColor.textPrimary,
                    borderWidth: SGBorder.regular,
                    shadowOffset: SGShadow.small,
                    fullWidth: true
                )
            )
            .disabled(isSaving)
        }
    }

    private func addDomain() {
        let candidate = newDomainInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        switch SplitDNSConfiguration.validateDomain(candidate, existing: domains) {
        case .success(let normalized):
            withAnimation(.snappy(duration: 0.2)) {
                domains.append(.init(name: normalized))
                newDomainInput = ""
                inputError = nil
            }
        case .failure(let error):
            inputError = error.localizedDescription
        }
    }

    private func applyAndDismiss() {
        let pending = newDomainInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty {
            addDomain()
            if inputError != nil { return }
        }
        isSaving = true
        store.applySplitDNSSuggestion(for: prompt.tunnelID, domains: domains) { succeeded in
            isSaving = false
            if succeeded {
                dismiss()
            }
        }
    }
}
