import SplitGuardCore
import SwiftUI

/// Names that always use the network's normal DNS. In "all domains" mode this is the main list;
/// in "only selected domains" mode it is an optional carve-out and stays collapsed until needed.
struct SplitDNSExceptionsCard: View {
    @Bindable var viewModel: TunnelEditorViewModel

    @State private var isRevealed = false

    private var exceptions: [SplitDNSConfiguration.Exclusion] {
        viewModel.visibleSplitDNSExceptions
    }

    private var isCollapsible: Bool {
        viewModel.splitDNSMode == .onlyDomains
    }

    private var showsEditor: Bool {
        !isCollapsible
            || isRevealed
            || !exceptions.isEmpty
            || !viewModel.exceptionWarnings.isEmpty
            || !viewModel.newSplitDNSExclusion.isEmpty
            || viewModel.splitDNSExclusionInputError != nil
    }

    private var description: String {
        switch viewModel.splitDNSMode {
        case .allDomains:
            return "These names skip the VPN's DNS and use your network's normal DNS instead."
        case .onlyDomains:
            return "Names inside your VPN domains that should still use normal DNS, such as a public website."
        }
    }

    var body: some View {
        EditorCard(
            title: "Exceptions",
            trailingText: exceptions.isEmpty ? "NONE" : "\(exceptions.count)",
            trailingFill: exceptions.isEmpty ? SGColor.surfaceElevated : SGColor.popYellow,
            trailingForeground: exceptions.isEmpty ? SGColor.textPrimary : SGColor.inkOnPop
        ) {
            Text(description)
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if showsEditor {
                editorContent
            } else {
                revealButton
            }
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        if let suggestedExclusion = viewModel.suggestedEndpointExclusion {
            endpointExclusionSuggestionRow(domain: suggestedExclusion)
        }

        if exceptions.isEmpty {
            SplitDNSEmptyState(systemImage: "arrow.uturn.left", message: "No exceptions yet.")
        } else {
            VStack(spacing: SGSpacing.xSmall) {
                ForEach(exceptions) { exclusion in
                    exceptionRow(exclusion)
                }
            }
        }

        ForEach(viewModel.exceptionWarnings) { warning in
            warningRow(warning)
        }

        SplitDNSAddField(
            placeholder: "Add name, e.g. www.example.com",
            text: $viewModel.newSplitDNSExclusion,
            errorText: viewModel.splitDNSExclusionInputError,
            onTextChange: { viewModel.splitDNSExclusionInputError = nil },
            onAdd: { viewModel.addSplitDNSExclusion() }
        )

        Text(
            "Applies to standard DNS lookups (UDP port 53). Encrypted DNS and DNS over TCP are not redirected, "
                + "and traffic still follows Allowed IPs."
        )
        .font(SGTypography.caption)
        .foregroundStyle(SGColor.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var revealButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                isRevealed = true
            }
        } label: {
            HStack(spacing: SGSpacing.xSmall) {
                Image(systemName: "plus")
                    .font(.caption.weight(.black))
                Text("ADD EXCEPTION")
                    .font(SGTypography.displayCompact)
                    .tracking(0.8)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(
            BrutalistButtonStyle(
                fill: SGColor.surfaceElevated,
                foreground: SGColor.textPrimary,
                borderWidth: SGBorder.thin,
                shadowOffset: SGShadow.small,
                fullWidth: true
            )
        )
    }

    private func exceptionRow(_ exclusion: SplitDNSConfiguration.Exclusion) -> some View {
        SplitDNSNameRow(
            name: exclusion.name,
            matchDescription: exclusion.includesSubdomains
                ? "\(exclusion.name) and *.\(exclusion.name)"
                : "\(exclusion.name) only",
            scope: SplitDNSScopeMenu(
                isWide: exclusion.includesSubdomains,
                wideTitle: "Name and subdomains",
                narrowTitle: "This name only",
                wideLabel: "+ Subdomains",
                narrowLabel: "Exact name",
                accessibilityName: exclusion.name
            ) { wide in
                withAnimation(.snappy(duration: 0.2)) {
                    viewModel.setSplitDNSExclusionIncludesSubdomains(wide, for: exclusion.name)
                }
            },
            onRemove: {
                withAnimation(.snappy(duration: 0.2)) {
                    viewModel.removeSplitDNSExclusion(named: exclusion.name)
                }
            }
        )
    }

    private func warningRow(_ warning: SplitDNSConfiguration.ValidationWarning) -> some View {
        switch warning {
        case .exclusionCancelsDomain(let name):
            return SplitDNSWarningRow(
                warning: warning,
                fixTitle: "EXCLUDE \(name.uppercased()) ONLY",
                onFixAction: {
                    withAnimation(.snappy(duration: 0.2)) {
                        viewModel.setSplitDNSExclusionIncludesSubdomains(false, for: name)
                    }
                }
            )
        case .exclusionOutsideMatchDomains(let name):
            return SplitDNSWarningRow(
                warning: warning,
                fixTitle: "REMOVE \(name.uppercased())",
                onFixAction: {
                    withAnimation(.snappy(duration: 0.2)) {
                        viewModel.removeSplitDNSExclusion(named: name)
                    }
                }
            )
        default:
            return SplitDNSWarningRow(warning: warning)
        }
    }

    private func endpointExclusionSuggestionRow(domain: String) -> some View {
        HStack(spacing: SGSpacing.small) {
            Image(systemName: "network")
                .font(.subheadline.weight(.black))
                .foregroundStyle(SGColor.inkOnPop)

            VStack(alignment: .leading, spacing: 2) {
                Text("Keep \(domain) on normal DNS?")
                    .font(SGTypography.subheadline)
                    .foregroundStyle(SGColor.inkOnPop)
                Text("This is the peer endpoint, so it can always be resolved before the tunnel is up.")
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.inkOnPop.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: SGSpacing.xSmall)

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    viewModel.applySuggestedEndpointExclusion()
                }
            } label: {
                Text("EXCLUDE")
                    .font(SGTypography.displayCompact)
                    .tracking(0.8)
                    .padding(.horizontal, SGSpacing.small)
                    .padding(.vertical, 6)
            }
            .buttonStyle(
                BrutalistButtonStyle(
                    fill: SGColor.popYellow,
                    foreground: SGColor.inkOnPop,
                    borderWidth: SGBorder.thin,
                    shadowOffset: 2,
                    shadowColor: SGColor.shadowInk
                )
            )
        }
        .padding(SGSpacing.small)
        .background(SGColor.popPurple)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.regular))
    }
}
