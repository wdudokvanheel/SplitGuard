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
                if enableSwipeBack {
                    BrutalistInteractivePopEnabler()
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
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
        .accessibilityLabel("Back")
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

    var body: some View {
        HStack(spacing: SGSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SGTypography.bodyBold)
                    .foregroundStyle(SGColor.textPrimary)
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
                isInteractive: true,
                accessibilityLabelText: title
            ) { newValue in
                isOn = newValue
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Brutalist Add Tunnel Sheet (Replaces Native Popover Menu)

struct BrutalistAddTunnelSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onScanQRCode: () -> Void
    let onImportFiles: () -> Void
    let onCreateFromScratch: () -> Void
    let onPasteConfig: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: "Add Tunnel",
                subtitle: "Choose import method",
                trailing: {
                    BrutalistHeaderButton(
                        title: tr("actionCancel"),
                        fill: SGColor.surfaceCard,
                        foreground: SGColor.textPrimary
                    ) {
                        dismiss()
                    }
                }
            )

            ScrollView {
                VStack(spacing: SGSpacing.small) {
                    AddTunnelActionRow(
                        title: tr("addTunnelMenuQRCode").uppercased(),
                        subtitle: "Scan a WireGuard QR code with camera",
                        systemImage: "qrcode.viewfinder",
                        fill: SGColor.popPink,
                        foreground: SGColor.pureWhite,
                        showGrain: true
                    ) {
                        triggerAfterDismiss(onScanQRCode)
                    }

                    AddTunnelActionRow(
                        title: tr("addTunnelMenuImportFile").uppercased(),
                        subtitle: "Pick a .conf file or .zip archive",
                        systemImage: "doc.badge.plus",
                        fill: SGColor.pureWhite,
                        foreground: SGColor.inkOnPop,
                        badgeAccent: SGColor.popGreen,
                        showGrain: false
                    ) {
                        triggerAfterDismiss(onImportFiles)
                    }

                    AddTunnelActionRow(
                        title: tr("addTunnelMenuFromScratch").uppercased(),
                        subtitle: "Generate keys and configure manually",
                        systemImage: "square.and.pencil",
                        fill: SGColor.popYellow,
                        foreground: SGColor.inkOnPop,
                        showGrain: true
                    ) {
                        triggerAfterDismiss(onCreateFromScratch)
                    }

                    AddTunnelActionRow(
                        title: "PASTE CONFIGURATION",
                        subtitle: "Paste a wg-quick config from clipboard",
                        systemImage: "doc.on.clipboard",
                        fill: SGColor.popPurple,
                        foreground: SGColor.inkOnPop,
                        showGrain: true
                    ) {
                        triggerAfterDismiss(onPasteConfig)
                    }
                }
                .padding(SGSpacing.medium)
            }
            .background(SGColor.surfacePrimary.ignoresSafeArea())
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }

    private func triggerAfterDismiss(_ action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            action()
        }
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
    func makeUIViewController(context: Context) -> PopEnablerController {
        PopEnablerController()
    }

    func updateUIViewController(_ uiViewController: PopEnablerController, context: Context) {
        uiViewController.enableInteractivePop()
    }

    final class PopEnablerController: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enableInteractivePop()
        }

        func enableInteractivePop() {
            guard let nav = navigationController, nav.viewControllers.count > 1 else { return }
            nav.interactivePopGestureRecognizer?.isEnabled = true
            nav.interactivePopGestureRecognizer?.delegate = nil
        }
    }
}
