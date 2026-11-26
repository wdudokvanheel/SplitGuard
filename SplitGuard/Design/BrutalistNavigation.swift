import SwiftUI
import UIKit

// MARK: - Brutalist Navigation Header Bar

struct BrutalistHeaderBar<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var enableSwipeBack: Bool = false
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        enableSwipeBack: Bool = false,
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.enableSwipeBack = enableSwipeBack
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SGSpacing.small) {
                leading()

                VStack(alignment: .leading, spacing: 0) {
                    Text(title.uppercased())
                        .font(SGTypography.displayTitle)
                        .tracking(1.0)
                        .foregroundStyle(SGColor.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    if let subtitle {
                        Text(subtitle.uppercased())
                            .font(SGTypography.metricLabel)
                            .tracking(0.8)
                            .foregroundStyle(SGColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailing()
            }
            .padding(.horizontal, SGSpacing.medium)
            .padding(.vertical, SGSpacing.small)
            .background(SGColor.surfacePrimary)
            .background {
                BrutalistInteractivePopEnabler(isEnabled: enableSwipeBack)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            Rectangle()
                .fill(SGColor.borderInk)
                .frame(height: SGBorder.regular)
        }
    }
}

// MARK: - Brutalist Header Buttons

struct BrutalistBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .black))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(
            BrutalistButtonStyle(
                fill: SGColor.surfaceCard,
                foreground: SGColor.textPrimary,
                borderWidth: SGBorder.regular,
                shadowOffset: SGShadow.small,
                cornerRadius: SGRadius.sharp
            )
        )
        .accessibilityLabel(L10n.tr("action.back", defaultValue: "Back"))
    }
}

struct BrutalistHeaderButton: View {
    let title: String
    var systemImage: String?
    var fill: Color = SGColor.surfaceCard
    var foreground: Color = SGColor.textPrimary
    var showGrain: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .black))
                }
                Text(title.uppercased())
                    .font(SGTypography.displayCompact)
                    .tracking(0.8)
            }
            .padding(.horizontal, SGSpacing.small)
            .frame(height: 38)
        }
        .buttonStyle(
            BrutalistButtonStyle(
                fill: fill,
                foreground: foreground,
                borderWidth: SGBorder.regular,
                shadowOffset: SGShadow.small,
                cornerRadius: SGRadius.sharp,
                showGrain: showGrain
            )
        )
    }
}

// MARK: - Brutalist Form Primitives

struct BrutalistFormToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var activeTint: Color = SGColor.popGreen
    var isInteractive: Bool = true

    var body: some View {
        HStack(spacing: SGSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SGTypography.bodyBold)
                    .foregroundStyle(isInteractive ? SGColor.textPrimary : SGColor.textTertiary)
                if let subtitle {
                    Text(subtitle)
                        .font(SGTypography.caption)
                        .foregroundStyle(SGColor.textSecondary)
                }
            }
            Spacer(minLength: SGSpacing.xSmall)
            BrutalistToggle(
                isOn: isOn,
                activeTint: activeTint,
                isInteractive: isInteractive,
                accessibilityLabelText: title
            ) { newValue in
                isOn = newValue
            }
        }
        .padding(.vertical, 4)
    }
}

/// Collapsible group for rarely changed fields, so cards stay short by default.
struct BrutalistDisclosure<Content: View>: View {
    let title: String
    var summary: String?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: SGSpacing.small) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: SGSpacing.xSmall) {
                    Text(title.uppercased())
                        .font(SGTypography.metricLabel)
                        .tracking(0.8)
                        .foregroundStyle(SGColor.textSecondary)
                    if let summary, !isExpanded {
                        Text(summary)
                            .font(SGTypography.caption)
                            .foregroundStyle(SGColor.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: SGSpacing.xSmall)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.black))
                        .foregroundStyle(SGColor.textPrimary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                isExpanded
                    ? Text(L10n.tr("common.expanded", defaultValue: "Expanded"))
                    : Text(L10n.tr("common.collapsed", defaultValue: "Collapsed"))
            )

            if isExpanded {
                content()
            }
        }
    }
}

// MARK: - Brutalist Add Tunnel Page

struct BrutalistAddTunnelSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onScanQRCode: () -> Void
    let onImportFiles: () -> Void
    let onCreateFromScratch: () -> Void
    let onPasteConfig: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: L10n.tr("addTunnel.title", defaultValue: "Add Tunnel"),
                subtitle: L10n.tr("addTunnel.subtitle", defaultValue: "Choose import method"),
                enableSwipeBack: true,
                leading: {
                    BrutalistBackButton {
                        dismiss()
                    }
                }
            )

            ScrollView {
                VStack(spacing: SGSpacing.small) {
                    AddTunnelActionRow(
                        title: L10n.tr("addTunnel.menu.qrCode", defaultValue: "Create from QR code").uppercased(),
                        subtitle: L10n.tr("addTunnel.menu.qrCode.subtitle", defaultValue: "Scan a WireGuard QR code with camera"),
                        systemImage: "qrcode.viewfinder",
                        fill: SGColor.popPink,
                        foreground: SGColor.pureWhite,
                        showGrain: true,
                        action: onScanQRCode
                    )

                    AddTunnelActionRow(
                        title: L10n.tr("addTunnel.menu.importFile", defaultValue: "Create from file").uppercased(),
                        subtitle: L10n.tr("addTunnel.menu.importFile.subtitle", defaultValue: "Pick one or more .conf files"),
                        systemImage: "doc.badge.plus",
                        fill: SGColor.pureWhite,
                        foreground: SGColor.inkOnPop,
                        badgeAccent: SGColor.popGreen,
                        showGrain: false,
                        action: onImportFiles
                    )

                    AddTunnelActionRow(
                        title: L10n.tr("addTunnel.menu.fromScratch", defaultValue: "Create from scratch").uppercased(),
                        subtitle: L10n.tr("addTunnel.menu.fromScratch.subtitle", defaultValue: "Generate keys and configure manually"),
                        systemImage: "square.and.pencil",
                        fill: SGColor.popYellow,
                        foreground: SGColor.inkOnPop,
                        showGrain: true,
                        action: onCreateFromScratch
                    )

                    AddTunnelActionRow(
                        title: L10n.tr("addTunnel.menu.pasteConfig", defaultValue: "Paste configuration").uppercased(),
                        subtitle: L10n.tr("addTunnel.menu.pasteConfig.subtitle", defaultValue: "Paste a wg-quick config from clipboard"),
                        systemImage: "doc.on.clipboard",
                        fill: SGColor.popBlue,
                        foreground: SGColor.inkOnPop,
                        showGrain: true,
                        action: onPasteConfig
                    )
                }
                .padding(SGSpacing.medium)
                .padding(.bottom, SGSpacing.xxLarge)
            }
            .background(SGColor.surfacePrimary.ignoresSafeArea())
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct AddTunnelActionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let fill: Color
    let foreground: Color
    var badgeAccent: Color?
    let showGrain: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SGSpacing.small) {
                Image(systemName: systemImage)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(badgeAccent != nil ? SGColor.inkOnPop : foreground)
                    .frame(width: 36, height: 36)
                    .background(badgeAccent ?? Color.clear)
                    .overlay {
                        if badgeAccent != nil {
                            Rectangle().strokeBorder(SGColor.pureBlack, lineWidth: 1.5)
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SGTypography.displayCompact)
                        .tracking(0.8)
                    Text(subtitle)
                        .font(SGTypography.caption)
                        .opacity(0.84)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.black))
            }
            .padding(.horizontal, SGSpacing.medium)
            .padding(.vertical, 12)
        }
        .buttonStyle(
            BrutalistButtonStyle(
                fill: fill,
                foreground: foreground,
                borderWidth: SGBorder.regular,
                shadowOffset: SGShadow.small,
                fullWidth: true,
                showGrain: showGrain
            )
        )
    }
}

// MARK: - Preserve Swipe-Back Gesture When Native Navigation Bar Is Hidden

private struct BrutalistInteractivePopEnabler: UIViewControllerRepresentable {
    let isEnabled: Bool

    func makeUIViewController(context: Context) -> PopEnablerController {
        PopEnablerController(isSwipeBackEnabled: isEnabled)
    }

    func updateUIViewController(_ uiViewController: PopEnablerController, context: Context) {
        uiViewController.isSwipeBackEnabled = isEnabled
        uiViewController.syncInteractivePop()
    }

    final class PopEnablerController: UIViewController, UIGestureRecognizerDelegate {
        var isSwipeBackEnabled: Bool

        init(isSwipeBackEnabled: Bool) {
            self.isSwipeBackEnabled = isSwipeBackEnabled
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            syncInteractivePop()
        }

        func syncInteractivePop() {
            guard let nav = navigationController else { return }
            let canPop = isSwipeBackEnabled && nav.viewControllers.count > 1
            nav.interactivePopGestureRecognizer?.isEnabled = canPop
            nav.interactivePopGestureRecognizer?.delegate = self
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let nav = navigationController else { return false }
            return isSwipeBackEnabled && nav.viewControllers.count > 1
        }
    }
}
