import SwiftUI
import WireGuardKit

struct SplitDNSEditorSection: View {
    @Bindable var viewModel: TunnelEditorViewModel
    let isTunnelActive: Bool

    var body: some View {
        Section {
            Picker("DNS Mode", selection: $viewModel.splitDNSMode) {
                Text("All domains").tag(SplitDNSConfiguration.Mode.allDomains)
                Text("Only these domains").tag(SplitDNSConfiguration.Mode.onlyDomains)
            }
            .pickerStyle(.segmented)
            .onChange(of: viewModel.splitDNSMode) { _, _ in
                viewModel.splitDNSInputError = nil
            }

            if let suggested = viewModel.suggestedEndpointDomain {
                suggestionRow(domain: suggested)
            }

            if viewModel.splitDNSMode == .onlyDomains {
                domainRows
                addDomainRow
                if let errorText = viewModel.splitDNSInputError {
                    Label(errorText, systemImage: "exclamationmark.circle.fill")
                        .font(SGTypography.caption)
                        .foregroundStyle(SGColor.statusError)
                }
                ForEach(viewModel.splitDNSWarnings) { warning in
                    SplitDNSWarningRow(warning: warning)
                }
            }

            SplitDNSRoutingPreviewView(
                splitDNS: viewModel.splitDNSConfiguration,
                dnsServers: viewModel.currentDNSServers
            )

            SplitDNSNameTesterView(
                splitDNS: viewModel.splitDNSConfiguration,
                dnsServers: viewModel.currentDNSServers,
                isTunnelActive: isTunnelActive
            )
        } header: {
            Text("Split DNS")
        } footer: {
            Text(footerDescription)
        }
    }

    private var footerDescription: String {
        switch viewModel.splitDNSMode {
        case .allDomains:
            return "Every DNS query uses the tunnel's DNS servers (standard WireGuard behavior)."
        case .onlyDomains:
            return "Only listed domains and their subdomains use the tunnel's DNS server. Everything else uses the network's normal DNS."
        }
    }

    private func suggestionRow(domain: String) -> some View {
        HStack(spacing: SGSpacing.small) {
            Image(systemName: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SGColor.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Use VPN DNS for \(domain) and its subdomains?")
                    .font(SGTypography.subheadline)
                    .foregroundStyle(SGColor.textPrimary)
                Text("Detected from peer endpoint")
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.textSecondary)
            }

            Spacer(minLength: SGSpacing.xSmall)

            Button("Use") {
                withAnimation(.snappy(duration: 0.2)) {
                    viewModel.applySuggestedEndpointDomain()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityLabel("Use VPN DNS for \(domain)")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var domainRows: some View {
        if viewModel.splitDNSDomains.isEmpty {
            Text("No domains added yet")
                .font(SGTypography.subheadline)
                .foregroundStyle(SGColor.textTertiary)
        } else {
            ForEach(viewModel.splitDNSDomains) { domain in
                HStack(spacing: SGSpacing.small) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(domain.name)
                            .font(SGTypography.monoValue)
                            .foregroundStyle(SGColor.textPrimary)
                        Text("Matches \(domain.name) and *.\(domain.name)")
                            .font(SGTypography.caption)
                            .foregroundStyle(SGColor.textSecondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        withAnimation(.snappy(duration: 0.2)) {
                            viewModel.removeSplitDNSDomain(named: domain.name)
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(SGColor.statusError)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(domain.name)")
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var addDomainRow: some View {
        HStack(spacing: SGSpacing.small) {
            TextField("Add domain (e.g. hw45.nl)", text: $viewModel.newSplitDNSDomain)
                .font(SGTypography.monoValue)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .onChange(of: viewModel.newSplitDNSDomain) { _, _ in
                    viewModel.splitDNSInputError = nil
                }
                .onSubmit {
                    _ = viewModel.addSplitDNSDomain()
                }

            Button("Add") {
                withAnimation(.snappy(duration: 0.2)) {
                    _ = viewModel.addSplitDNSDomain()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.newSplitDNSDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

struct SplitDNSDetailSection: View {
    let splitDNS: SplitDNSConfiguration
    let dnsServers: [DNSServer]
    let warnings: [SplitDNSConfiguration.ValidationWarning]
    let isTunnelActive: Bool

    private var modeLabel: String {
        switch splitDNS.mode {
        case .allDomains:
            return "All domains"
        case .onlyDomains:
            return "Only these domains"
        }
    }

    var body: some View {
        Section("Split DNS") {
            LabeledContent("Mode", value: modeLabel)

            if splitDNS.mode == .onlyDomains {
                if splitDNS.domains.isEmpty {
                    Text("No domains configured")
                        .font(SGTypography.subheadline)
                        .foregroundStyle(SGColor.textTertiary)
                } else {
                    ForEach(splitDNS.domains) { domain in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(domain.name)
                                .font(SGTypography.monoValue)
                                .foregroundStyle(SGColor.textPrimary)
                            Text("Matches \(domain.name) and *.\(domain.name)")
                                .font(SGTypography.caption)
                                .foregroundStyle(SGColor.textSecondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                ForEach(warnings) { warning in
                    SplitDNSWarningRow(warning: warning)
                }
            }

            SplitDNSRoutingPreviewView(splitDNS: splitDNS, dnsServers: dnsServers)

            SplitDNSNameTesterView(
                splitDNS: splitDNS,
                dnsServers: dnsServers,
                isTunnelActive: isTunnelActive
            )
        }
    }
}
