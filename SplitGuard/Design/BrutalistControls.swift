import SwiftUI
import UIKit

// MARK: - Brutalist Toggle Switch

struct BrutalistToggle: View {
    let isOn: Bool
    let activeTint: Color
    let isInteractive: Bool
    let accessibilityLabelText: String
    var shadowColor: Color = SGColor.shadowSurface
    let onToggle: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            guard isInteractive else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onToggle(!isOn)
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: SGRadius.sharp, style: .continuous)
                    .fill(isOn ? activeTint : SGColor.surfaceElevated)
                    .frame(width: 56, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: SGRadius.sharp, style: .continuous)
                            .strokeBorder(SGColor.borderInk, lineWidth: SGBorder.regular)
                    )

                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(isOn ? SGColor.pureWhite : SGColor.borderInk)
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .strokeBorder(SGColor.borderInk, lineWidth: 1.5)
                    )
                    .padding(5)
            }
            .background(
                RoundedRectangle(cornerRadius: SGRadius.sharp, style: .continuous)
                    .fill(shadowColor)
                    .offset(x: 2.5, y: 2.5)
            )
            .opacity(isInteractive ? 1 : 0.5)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isOn)
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Brutalist Segmented Picker

struct BrutalistSegmentedControl<Selection: Hashable>: View {
    struct Option: Identifiable {
        let value: Selection
        let title: String
        let accent: Color
        let systemImage: String?
        let showsAlert: Bool

        var id: Selection { value }

        init(
            value: Selection,
            title: String,
            accent: Color,
            systemImage: String? = nil,
            showsAlert: Bool = false
        ) {
            self.value = value
            self.title = title
            self.accent = accent
            self.systemImage = systemImage
            self.showsAlert = showsAlert
        }
    }

    @Binding var selection: Selection
    let options: [Option]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                let isSelected = selection == option.value
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if reduceMotion {
                        selection = option.value
                    } else {
                        withAnimation(.snappy(duration: 0.18)) {
                            selection = option.value
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if let systemImage = option.systemImage {
                            Image(systemName: systemImage)
                                .font(.system(size: 11, weight: .bold))
                        }
                        Text(option.title.uppercased())
                            .font(SGTypography.badge)
                            .tracking(0.6)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        if option.showsAlert {
                            Rectangle()
                                .fill(SGColor.statusError)
                                .frame(width: 7, height: 7)
                                .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1))
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(isSelected ? SGColor.inkOnPop : SGColor.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .padding(.horizontal, SGSpacing.xSmall)
                    .background(isSelected ? option.accent : SGColor.surfaceCard)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityValue(option.showsAlert ? Text("Needs attention") : Text(""))

                if index < options.count - 1 {
                    Rectangle()
                        .fill(SGColor.borderInk)
                        .frame(width: SGBorder.regular)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.sharp, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SGRadius.sharp, style: .continuous)
                .strokeBorder(SGColor.borderInk, lineWidth: SGBorder.regular)
        )
        .background(
            RoundedRectangle(cornerRadius: SGRadius.sharp, style: .continuous)
                .fill(SGColor.shadowSurface)
                .offset(x: 3, y: 3)
        )
    }
}

// MARK: - Brutalist Ticker Bar (Matching Portfolio TechMarquee)

struct BrutalistTickerBar: View {
    let items: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    private var joinedLine: String {
        items.map { $0.uppercased() }.joined(separator: "  —  ") + "  —  "
    }

    var body: some View {
        Group {
            if reduceMotion {
                Text(items.map { $0.uppercased() }.joined(separator: " • "))
                    .font(SGTypography.displayCompact)
                    .tracking(1.0)
                    .foregroundStyle(SGColor.invertedBarText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SGSpacing.small)
                    .padding(.vertical, SGSpacing.xSmall)
                    .frame(maxWidth: .infinity)
            } else {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        tickerUnit
                        tickerUnit
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: animate ? -max(proxy.size.width, 320) : 0)
                    .animation(
                        .linear(duration: 18).repeatForever(autoreverses: false),
                        value: animate
                    )
                    .frame(height: proxy.size.height, alignment: .center)
                    .onAppear {
                        animate = true
                    }
                }
                .frame(height: 36)
                .clipped()
            }
        }
        .background(SGColor.invertedBar)
        .overlay(
            Rectangle()
                .strokeBorder(SGColor.borderInk, lineWidth: SGBorder.regular)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(items.joined(separator: ", "))
    }

    private var tickerUnit: some View {
        Text(joinedLine + joinedLine)
            .font(SGTypography.displayCompact)
            .tracking(1.2)
            .foregroundStyle(SGColor.invertedBarText)
            .fixedSize()
    }
}

// MARK: - Brutalist Icon Action Button

struct BrutalistIconButton: View {
    let systemImage: String
    let accessibilityLabelText: String
    var fill: Color = SGColor.surfaceCard
    var foreground: Color = SGColor.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(
            BrutalistButtonStyle(
                fill: fill,
                foreground: foreground,
                borderWidth: SGBorder.regular,
                shadowOffset: SGShadow.small,
                cornerRadius: SGRadius.sharp
            )
        )
        .accessibilityLabel(accessibilityLabelText)
    }
}

// MARK: - Brutalist Empty / Unavailable Card

struct BrutalistUnavailableCard: View {
    let title: String
    let message: String
    let systemImage: String
    var accent: Color = SGColor.popYellow

    var body: some View {
        VStack(spacing: SGSpacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(SGColor.inkOnPop)
                .frame(width: 60, height: 60)
                .background(accent)
                .overlay(
                    Rectangle()
                        .strokeBorder(SGColor.borderInk, lineWidth: SGBorder.regular)
                )

            Text(title.uppercased())
                .font(SGTypography.displaySection)
                .tracking(1.0)
                .foregroundStyle(SGColor.textPrimary)
                .multilineTextAlignment(.center)

            Text(message)
                .font(SGTypography.subheadline)
                .foregroundStyle(SGColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(SGSpacing.xLarge)
        .frame(maxWidth: .infinity)
        .brutalistCard(fill: SGColor.surfaceCard)
        .padding(SGSpacing.medium)
    }
}
