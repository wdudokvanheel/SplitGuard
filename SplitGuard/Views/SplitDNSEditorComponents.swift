import SwiftUI
import UIKit

// MARK: - Shared Editor Building Blocks

struct EditorCard<Content: View>: View {
    let title: String
    var trailingText: String?
    var trailingFill: Color = SGColor.popYellow
    var trailingForeground: Color = SGColor.inkOnPop
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(
                title: title,
                trailingText: trailingText,
                trailingFill: trailingFill,
                trailingForeground: trailingForeground
            )

            VStack(alignment: .leading, spacing: SGSpacing.small) {
                content()
            }
            .padding(SGSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }
}

struct SplitDNSEmptyState: View {
    let systemImage: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: SGSpacing.xSmall) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(SGColor.textSecondary)
                .padding(.top, 2)
            Text(message)
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SGSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SGColor.surfaceElevated)
        .overlay(
            Rectangle()
                .strokeBorder(style: StrokeStyle(lineWidth: SGBorder.thin, dash: [5, 3]))
                .foregroundStyle(SGColor.borderSubtle)
        )
    }
}

struct SplitDNSNameRow: View {
    let name: String
    let matchDescription: String
    let scope: SplitDNSScopeMenu
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: SGSpacing.small) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(SGTypography.monoValue.weight(.semibold))
                    .foregroundStyle(SGColor.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Text(matchDescription)
                    .font(SGTypography.monoCompact)
                    .foregroundStyle(SGColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                scope
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.black))
                    .foregroundStyle(SGColor.pureWhite)
                    .frame(width: 28, height: 28)
                    .background(SGColor.popRed)
                    .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("splitDNS.action.removeAccessibility", defaultValue: "Remove \(name)"))
        }
        .padding(SGSpacing.xSmall)
        .background(SGColor.surfaceElevated)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
    }
}

/// Compact pill that switches a rule between covering the name plus subdomains ("wide")
/// and a narrower match.
struct SplitDNSScopeMenu: View {
    let isWide: Bool
    let wideTitle: String
    let narrowTitle: String
    let wideLabel: String
    let narrowLabel: String
    let accessibilityName: String
    let onSelect: (Bool) -> Void

    var body: some View {
        Menu {
            Button {
                onSelect(true)
            } label: {
                if isWide {
                    Label(wideTitle, systemImage: "checkmark")
                } else {
                    Text(wideTitle)
                }
            }
            Button {
                onSelect(false)
            } label: {
                if isWide {
                    Text(narrowTitle)
                } else {
                    Label(narrowTitle, systemImage: "checkmark")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text((isWide ? wideLabel : narrowLabel).uppercased())
                    .font(SGTypography.metricLabel)
                    .tracking(0.5)
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .black))
            }
            .foregroundStyle(SGColor.inkOnPop)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isWide ? SGColor.popYellow : SGColor.pureWhite)
            .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))
        }
        .accessibilityLabel(
            L10n.tr("splitDNS.scope.accessibility", defaultValue: "Match scope for \(accessibilityName)")
        )
        .accessibilityValue(isWide ? wideTitle : narrowTitle)
    }
}

struct SplitDNSAddField: View {
    let placeholder: String
    @Binding var text: String
    let errorText: String?
    let onTextChange: () -> Void
    let onAdd: () -> Bool

    @FocusState private var isFocused: Bool

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xxSmall) {
            HStack(spacing: SGSpacing.small) {
                TextField(placeholder, text: $text)
                    .font(SGTypography.monoValue)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .focused($isFocused)
                    .padding(.horizontal, SGSpacing.xSmall)
                    .padding(.vertical, 9)
                    .background(SGColor.surfaceElevated)
                    .overlay(
                        Rectangle().strokeBorder(
                            errorText == nil ? SGColor.borderInk : SGColor.statusError,
                            lineWidth: SGBorder.thin
                        )
                    )
                    .onChange(of: text) { _, _ in
                        onTextChange()
                    }
                    .onSubmit(add)

                Button(action: add) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.caption.weight(.black))
                        Text(L10n.tr("tunnels.list.add", defaultValue: "Add").uppercased())
                            .font(SGTypography.displayCompact)
                            .tracking(0.8)
                    }
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
                .disabled(trimmed.isEmpty)
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle.fill")
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.statusError)
            }
        }
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        var added = false
        withAnimation(.snappy(duration: 0.2)) {
            added = onAdd()
        }
        if added {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            isFocused = true
        }
    }
}

struct SplitDNSEndpointSuggestion: View {
    let domain: String
    let onApply: () -> Void

    var body: some View {
        HStack(spacing: SGSpacing.small) {
            Image(systemName: "sparkles")
                .font(.subheadline.weight(.black))
                .foregroundStyle(SGColor.inkOnPop)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("splitDNS.suggestion.useTitle", defaultValue: "Use VPN DNS for \(domain)?"))
                    .font(SGTypography.subheadline)
                    .foregroundStyle(SGColor.inkOnPop)
                Text(
                    L10n.tr(
                        "splitDNS.suggestion.useBody",
                        defaultValue: "Found in the peer endpoint. Covers its subdomains; the endpoint itself stays on normal DNS."
                    )
                )
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.inkOnPop.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: SGSpacing.xSmall)

            Button(action: onApply) {
                Text(L10n.tr("splitDNS.action.use", defaultValue: "Use").uppercased())
                    .font(SGTypography.displayCompact)
                    .tracking(0.8)
                    .padding(.horizontal, SGSpacing.small)
                    .padding(.vertical, 8)
            }
            .buttonStyle(
                BrutalistButtonStyle(
                    fill: SGColor.popGreen,
                    foreground: SGColor.inkOnPop,
                    borderWidth: SGBorder.thin,
                    shadowOffset: 2,
                    shadowColor: SGColor.shadowInk
                )
            )
            .padding(.trailing, 2)
            .accessibilityLabel(
                L10n.tr("splitDNS.suggestion.useAccessibility", defaultValue: "Use VPN DNS for \(domain)")
            )
        }
        .padding(SGSpacing.small)
        .background(SGColor.popBlue)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.regular))
    }
}
