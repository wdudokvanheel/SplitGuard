import SwiftUI
import UniformTypeIdentifiers

enum SGColor {
    static let accent = Color("AccentColor")
    static let surfacePrimary = Color(.systemGroupedBackground)
    static let surfaceCard = Color(.secondarySystemGroupedBackground)
    static let surfaceElevated = Color(.tertiarySystemGroupedBackground)
    static let textPrimary = Color(.label)
    static let textSecondary = Color(.secondaryLabel)
    static let textTertiary = Color(.tertiaryLabel)
    static let borderSubtle = Color(.separator).opacity(0.4)

    static let statusActive = Color.green
    static let statusTransitioning = Color.orange
    static let statusInactive = Color(.tertiaryLabel)
    static let statusOnDemand = Color.yellow
    static let statusError = Color.red
}

enum SGSpacing {
    static let xxSmall: CGFloat = 4
    static let xSmall: CGFloat = 8
    static let small: CGFloat = 12
    static let medium: CGFloat = 16
    static let large: CGFloat = 20
    static let xLarge: CGFloat = 24
    static let xxLarge: CGFloat = 32
}

enum SGRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let pill: CGFloat = 999
}

enum SGTypography {
    static let cardTitle = Font.headline
    static let sectionTitle = Font.subheadline.weight(.semibold)
    static let body = Font.body
    static let subheadline = Font.subheadline
    static let caption = Font.caption
    static let badge = Font.caption.weight(.semibold)
    static let metricValue = Font.subheadline.weight(.semibold).monospacedDigit()
    static let metricLabel = Font.caption2.weight(.medium)
    static let monoValue = Font.subheadline.monospaced()
    static let monoCompact = Font.caption.monospaced()
}

struct SGStatusBadge: View {
    let title: String
    let color: Color
    var isAnimated: Bool = false

    var body: some View {
        HStack(spacing: SGSpacing.xxSmall + 2) {
            if isAnimated {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text(title)
                .font(SGTypography.badge)
                .foregroundStyle(color == SGColor.statusInactive ? SGColor.textSecondary : color)
        }
        .padding(.horizontal, SGSpacing.xSmall + 2)
        .padding(.vertical, SGSpacing.xxSmall)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(color == SGColor.statusInactive ? 0.14 : 0.16))
        )
    }
}

extension UTType {
    static var wireGuardQuickConfig: UTType {
        UTType("com.wireguard.config.quick") ?? UTType(filenameExtension: "conf") ?? .plainText
    }

    static var splitGuardImportTypes: [UTType] {
        [.wireGuardQuickConfig, .zip, .plainText, .text]
    }
}
