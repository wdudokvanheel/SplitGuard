import SwiftUI
import UIKit

// MARK: - Brutalist Surface & Grain

struct BrutalistGrainOverlay: View {
    var opacity: Double = 0.22

    var body: some View {
        Image("GrainTexture")
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct BrutalistCardModifier: ViewModifier {
    let fill: Color
    let borderWidth: CGFloat
    let shadowOffset: CGFloat
    let cornerRadius: CGFloat
    let showGrain: Bool

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(fill)
                    if showGrain {
                        BrutalistGrainOverlay()
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(SGColor.borderInk, lineWidth: borderWidth)
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(SGColor.shadowInk)
                    .offset(x: shadowOffset, y: shadowOffset)
            )
    }
}

extension View {
    func brutalistCard(
        fill: Color = SGColor.surfaceCard,
        borderWidth: CGFloat = SGBorder.regular,
        shadowOffset: CGFloat = SGShadow.medium,
        cornerRadius: CGFloat = SGRadius.small,
        showGrain: Bool = false
    ) -> some View {
        modifier(
            BrutalistCardModifier(
                fill: fill,
                borderWidth: borderWidth,
                shadowOffset: shadowOffset,
                cornerRadius: cornerRadius,
                showGrain: showGrain
            )
        )
    }
}

// MARK: - Tactile Push-Into-Shadow Button

struct BrutalistButtonStyle: ButtonStyle {
    let fill: Color
    let foreground: Color
    let borderWidth: CGFloat
    let shadowOffset: CGFloat
    let cornerRadius: CGFloat
    let fullWidth: Bool
    let showGrain: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        fill: Color = SGColor.pureWhite,
        foreground: Color = SGColor.inkOnPop,
        borderWidth: CGFloat = SGBorder.regular,
        shadowOffset: CGFloat = SGShadow.medium,
        cornerRadius: CGFloat = SGRadius.sharp,
        fullWidth: Bool = false,
        showGrain: Bool = false
    ) {
        self.fill = fill
        self.foreground = foreground
        self.borderWidth = borderWidth
        self.shadowOffset = shadowOffset
        self.cornerRadius = cornerRadius
        self.fullWidth = fullWidth
        self.showGrain = showGrain
    }

    func makeBody(configuration: Configuration) -> some View {
        let effectiveShadow = isEnabled ? shadowOffset : 0
        let pressedShift = (isEnabled && configuration.isPressed) ? max(effectiveShadow - 1.5, 1.5) : 0
        let remainingShadow = max(effectiveShadow - pressedShift, 0)

        configuration.label
            .foregroundStyle(isEnabled ? foreground : foreground.opacity(0.55))
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isEnabled ? fill : fill.opacity(0.82))
                    if showGrain && isEnabled {
                        BrutalistGrainOverlay(opacity: 0.18)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(SGColor.borderInk.opacity(isEnabled ? 1 : 0.6), lineWidth: borderWidth)
            )
            .offset(x: pressedShift, y: pressedShift)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(SGColor.shadowInk)
                    .offset(x: remainingShadow + pressedShift, y: remainingShadow + pressedShift)
                    .opacity(isEnabled ? 1 : 0)
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed
            )
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed && isEnabled {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }
}

// MARK: - Inverted Section Bar (Matching Portfolio SERVICES Bar)

struct BrutalistSectionBar: View {
    let title: String
    var trailingText: String?

    var body: some View {
        HStack(spacing: SGSpacing.small) {
            Text(title.uppercased())
                .font(SGTypography.displaySection)
                .tracking(3.2)
                .foregroundStyle(SGColor.invertedBarText)

            Spacer(minLength: SGSpacing.xSmall)

            if let trailingText {
                Text(trailingText.uppercased())
                    .font(SGTypography.metricLabel)
                    .tracking(0.8)
                    .foregroundStyle(SGColor.inkOnPop)
                    .padding(.horizontal, SGSpacing.xSmall)
                    .padding(.vertical, 3)
                    .background(SGColor.popYellow)
                    .overlay(
                        Rectangle()
                            .strokeBorder(SGColor.pureBlack, lineWidth: 1.5)
                    )
            }
        }
        .padding(.horizontal, SGSpacing.medium)
        .padding(.vertical, SGSpacing.xSmall + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SGColor.invertedBar)
        .overlay(
            Rectangle()
                .strokeBorder(SGColor.borderInk, lineWidth: SGBorder.regular)
        )
    }
}

// MARK: - Block-Separated Tag Strip (Matching Portfolio ProjectCard)

struct BrutalistTagStrip: View {
    let tags: [String]
    var textColor: Color = SGColor.textPrimary
    var separatorColor: Color = SGColor.borderInk

    var body: some View {
        HStack(spacing: SGSpacing.xSmall) {
            ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                if index > 0 {
                    Rectangle()
                        .fill(separatorColor)
                        .frame(width: 4, height: 11)
                        .accessibilityHidden(true)
                }
                Text(tag.uppercased())
                    .font(SGTypography.metricLabel)
                    .tracking(0.4)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
            }
        }
    }
}
