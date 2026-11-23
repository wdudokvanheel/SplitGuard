import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum SGColor {
    // MARK: - Core Brutalist Palette (wdudokvanheel-portfolio)

    static let pureBlack = Color(red: 0.0, green: 0.0, blue: 0.0)
    static let pureWhite = Color(red: 1.0, green: 1.0, blue: 1.0)
    static let darkInk = Color(red: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0)
    static let creme = Color(red: 0xFE / 255.0, green: 0xFB / 255.0, blue: 0xE9 / 255.0)

    static let popBlue = adaptive(
        light: UIColor(red: 0x4D / 255.0, green: 0xCC / 255.0, blue: 0xFF / 255.0, alpha: 1),
        dark: UIColor(red: 0x3F / 255.0, green: 0xBD / 255.0, blue: 0xF0 / 255.0, alpha: 1)
    )
    static let popRed = adaptive(
        light: UIColor(red: 0xFF / 255.0, green: 0x4D / 255.0, blue: 0x4D / 255.0, alpha: 1),
        dark: UIColor(red: 0xF2 / 255.0, green: 0x4A / 255.0, blue: 0x4A / 255.0, alpha: 1)
    )
    static let popGreen = adaptive(
        light: UIColor(red: 0x74 / 255.0, green: 0xC9 / 255.0, blue: 0x36 / 255.0, alpha: 1),
        dark: UIColor(red: 0x6C / 255.0, green: 0xC0 / 255.0, blue: 0x30 / 255.0, alpha: 1)
    )
    static let popPurple = adaptive(
        light: UIColor(red: 0xB2 / 255.0, green: 0x6A / 255.0, blue: 0xFB / 255.0, alpha: 1),
        dark: UIColor(red: 0xA9 / 255.0, green: 0x63 / 255.0, blue: 0xF5 / 255.0, alpha: 1)
    )
    static let popYellow = adaptive(
        light: UIColor(red: 0xFF / 255.0, green: 0xC7 / 255.0, blue: 0x33 / 255.0, alpha: 1),
        dark: UIColor(red: 0xF7 / 255.0, green: 0xC0 / 255.0, blue: 0x2E / 255.0, alpha: 1)
    )
    static let popPink = Color(red: 0xFF / 255.0, green: 0x14 / 255.0, blue: 0x93 / 255.0)

    static let rowAccents: [Color] = [popRed, popGreen, popPurple, popBlue]

    // MARK: - Adaptive Semantic Surfaces & Ink

    static let accent = Color("AccentColor")

    static let surfacePrimary = adaptive(
        light: UIColor(red: 0xFE / 255.0, green: 0xFB / 255.0, blue: 0xE9 / 255.0, alpha: 1),
        dark: UIColor(red: 0x12 / 255.0, green: 0x11 / 255.0, blue: 0x10 / 255.0, alpha: 1)
    )

    static let surfaceCard = adaptive(
        light: UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1),
        dark: UIColor(red: 0x1E / 255.0, green: 0x1C / 255.0, blue: 0x18 / 255.0, alpha: 1)
    )

    static let surfaceElevated = adaptive(
        light: UIColor(red: 0xF4 / 255.0, green: 0xEE / 255.0, blue: 0xD6 / 255.0, alpha: 1),
        dark: UIColor(red: 0x2A / 255.0, green: 0x27 / 255.0, blue: 0x21 / 255.0, alpha: 1)
    )

    static let textPrimary = adaptive(
        light: UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1),
        dark: UIColor(red: 0xFE / 255.0, green: 0xFB / 255.0, blue: 0xE9 / 255.0, alpha: 1)
    )

    static let textSecondary = adaptive(
        light: UIColor(red: 0x2D / 255.0, green: 0x2C / 255.0, blue: 0x28 / 255.0, alpha: 1),
        dark: UIColor(red: 0xD6 / 255.0, green: 0xD0 / 255.0, blue: 0xBA / 255.0, alpha: 1)
    )

    static let textTertiary = adaptive(
        light: UIColor(red: 0x5B / 255.0, green: 0x58 / 255.0, blue: 0x4E / 255.0, alpha: 1),
        dark: UIColor(red: 0xA3 / 255.0, green: 0x9E / 255.0, blue: 0x8C / 255.0, alpha: 1)
    )

    static let borderInk = adaptive(
        light: UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1),
        dark: UIColor(red: 0xE4 / 255.0, green: 0xDD / 255.0, blue: 0xC4 / 255.0, alpha: 1)
    )

    static let borderSubtle = adaptive(
        light: UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.25),
        dark: UIColor(red: 0xE4 / 255.0, green: 0xDD / 255.0, blue: 0xC4 / 255.0, alpha: 0.20)
    )

    static let shadowInk = adaptive(
        light: UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1),
        dark: UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1)
    )

    static let shadowSurface = adaptive(
        light: UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1),
        dark: UIColor(red: 0x4A / 255.0, green: 0x45 / 255.0, blue: 0x39 / 255.0, alpha: 1)
    )

    static let invertedBar = adaptive(
        light: UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1),
        dark: UIColor(red: 0xE4 / 255.0, green: 0xDD / 255.0, blue: 0xC4 / 255.0, alpha: 1)
    )

    static let invertedBarText = adaptive(
        light: UIColor(red: 0xFE / 255.0, green: 0xFB / 255.0, blue: 0xE9 / 255.0, alpha: 1),
        dark: UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1)
    )

    static let inkOnPop = pureBlack

    // MARK: - Status & Feature Colors

    static let statusActive = popGreen
    static let statusTransitioning = popYellow
    static let statusInactive = adaptive(
        light: UIColor(red: 0x5B / 255.0, green: 0x58 / 255.0, blue: 0x4E / 255.0, alpha: 1),
        dark: UIColor(red: 0xA3 / 255.0, green: 0x9E / 255.0, blue: 0x8C / 255.0, alpha: 1)
    )
    static let statusOnDemand = popYellow
    static let statusError = popRed
    static let splitDNS = popBlue

    static func rowAccent(at index: Int) -> Color {
        rowAccents[abs(index) % rowAccents.count]
    }

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
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
    static let sharp: CGFloat = 2
    static let small: CGFloat = 4
    static let medium: CGFloat = 6
    static let large: CGFloat = 8
    static let pill: CGFloat = 999
}

enum SGBorder {
    static let thin: CGFloat = 1.5
    static let regular: CGFloat = 2.5
    static let thick: CGFloat = 3.5
}

enum SGShadow {
    static let small: CGFloat = 3
    static let medium: CGFloat = 5
    static let large: CGFloat = 6
}

enum SGTypography {
    static let displayHero = Font.custom("BebasNeue-Regular", size: 42, relativeTo: .largeTitle)
    static let displayTitle = Font.custom("BebasNeue-Regular", size: 32, relativeTo: .title)
    static let displaySection = Font.custom("BebasNeue-Regular", size: 24, relativeTo: .title2)
    static let displayButton = Font.custom("BebasNeue-Regular", size: 26, relativeTo: .title3)
    static let displayCompact = Font.custom("BebasNeue-Regular", size: 20, relativeTo: .headline)

    static let cardTitle = Font.custom("IBM Plex Sans", size: 17, relativeTo: .headline).weight(.bold)
    static let sectionTitle = Font.custom("IBM Plex Sans", size: 15, relativeTo: .subheadline).weight(.bold)
    static let body = Font.custom("IBM Plex Sans", size: 16, relativeTo: .body)
    static let bodyBold = Font.custom("IBM Plex Sans", size: 16, relativeTo: .body).weight(.bold)
    static let subheadline = Font.custom("IBM Plex Sans", size: 14, relativeTo: .subheadline).weight(.medium)
    static let caption = Font.custom("IBM Plex Sans", size: 13, relativeTo: .caption).weight(.medium)
    static let badge = Font.custom("IBM Plex Sans", size: 12, relativeTo: .caption).weight(.bold)
    static let metricValue = Font.custom("IBM Plex Sans", size: 15, relativeTo: .subheadline)
        .weight(.bold)
        .monospacedDigit()
    static let metricLabel = Font.custom("IBM Plex Sans", size: 11, relativeTo: .caption2).weight(.bold)
    static let monoValue = Font.subheadline.monospaced()
    static let monoCompact = Font.caption.monospaced()
}

struct SGStatusBadge: View {
    let title: String
    let color: Color
    var isAnimated: Bool = false
    var isInactive: Bool = false

    private var fillColor: Color {
        isInactive ? SGColor.surfaceElevated : color
    }

    private var foregroundColor: Color {
        isInactive ? SGColor.textPrimary : SGColor.inkOnPop
    }

    var body: some View {
        HStack(spacing: 6) {
            if isAnimated {
                ProgressView()
                    .controlSize(.mini)
                    .tint(foregroundColor)
            } else {
                Rectangle()
                    .fill(foregroundColor)
                    .frame(width: 7, height: 7)
            }
            Text(title.uppercased())
                .font(SGTypography.badge)
                .tracking(0.5)
                .foregroundStyle(foregroundColor)
                .lineLimit(1)
        }
        .padding(.horizontal, SGSpacing.xSmall)
        .padding(.vertical, SGSpacing.xxSmall)
        .background(fillColor)
        .overlay(
            Rectangle()
                .strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin)
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
