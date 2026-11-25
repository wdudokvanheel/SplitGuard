import SwiftUI
import UIKit

struct EditorTextRow<Accessory: View>: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let hasError: Bool
    let isMonospaced: Bool
    let keyboardType: UIKeyboardType
    @ViewBuilder let accessory: () -> Accessory

    init(
        label: String,
        placeholder: String,
        text: Binding<String>,
        hasError: Bool,
        isMonospaced: Bool,
        keyboardType: UIKeyboardType,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
        self.hasError = hasError
        self.isMonospaced = isMonospaced
        self.keyboardType = keyboardType
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xxSmall) {
            HStack(spacing: SGSpacing.xSmall) {
                Text(label.uppercased())
                    .font(SGTypography.metricLabel)
                    .tracking(0.6)
                    .foregroundStyle(hasError ? SGColor.statusError : SGColor.textSecondary)
                Spacer(minLength: 0)
                accessory()
            }

            TextField(placeholder, text: $text)
                .font(isMonospaced ? SGTypography.monoValue : SGTypography.body)
                .foregroundStyle(hasError ? SGColor.statusError : SGColor.textPrimary)
                .keyboardType(keyboardType)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, SGSpacing.xSmall)
                .padding(.vertical, 9)
                .background(SGColor.surfaceElevated)
                .overlay(
                    Rectangle()
                        .strokeBorder(hasError ? SGColor.statusError : SGColor.borderInk, lineWidth: SGBorder.thin)
                )
        }
    }
}

extension EditorTextRow where Accessory == EmptyView {
    init(
        label: String,
        placeholder: String,
        text: Binding<String>,
        hasError: Bool,
        isMonospaced: Bool,
        keyboardType: UIKeyboardType
    ) {
        self.init(
            label: label,
            placeholder: placeholder,
            text: text,
            hasError: hasError,
            isMonospaced: isMonospaced,
            keyboardType: keyboardType,
            accessory: { EmptyView() }
        )
    }
}
