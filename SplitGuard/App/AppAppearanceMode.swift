import SwiftUI
import UIKit

enum AppAppearanceMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case system
    case light
    case dark

    static let defaultsKey = "splitguard.appearanceMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system:
            return "circle.lefthalf.filled"
        case .light:
            return "sun.max.fill"
        case .dark:
            return "moon.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .system:
            return SGColor.popBlue
        case .light:
            return SGColor.popYellow
        case .dark:
            return SGColor.popPurple
        }
    }

    var descriptionText: String {
        switch self {
        case .system:
            return "Follows your device's system appearance setting."
        case .light:
            return "Always uses light mode, regardless of system appearance."
        case .dark:
            return "Always uses dark mode, regardless of system appearance."
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system:
            return .unspecified
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    static func load(from userDefaults: UserDefaults = .standard) -> AppAppearanceMode {
        guard let rawValue = userDefaults.string(forKey: defaultsKey),
              let mode = AppAppearanceMode(rawValue: rawValue) else {
            return .system
        }
        return mode
    }

    func save(to userDefaults: UserDefaults = .standard) {
        userDefaults.set(rawValue, forKey: Self.defaultsKey)
    }

    @MainActor
    func apply(to windowScene: UIWindowScene) {
        for window in windowScene.windows {
            window.overrideUserInterfaceStyle = userInterfaceStyle
        }
    }

    @MainActor
    func applyToConnectedWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            apply(to: windowScene)
        }
    }
}

struct WindowAppearanceBridge: UIViewRepresentable {
    let mode: AppAppearanceMode

    func makeUIView(context: Context) -> AppearanceHostView {
        let view = AppearanceHostView()
        view.mode = mode
        return view
    }

    func updateUIView(_ uiView: AppearanceHostView, context: Context) {
        uiView.mode = mode
        uiView.applyAppearance()
    }

    final class AppearanceHostView: UIView {
        var mode: AppAppearanceMode = .system

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyAppearance()
        }

        func applyAppearance() {
            let style = mode.userInterfaceStyle
            if let window {
                window.overrideUserInterfaceStyle = style
                if let scene = window.windowScene {
                    mode.apply(to: scene)
                }
            } else {
                mode.applyToConnectedWindows()
            }
        }
    }
}
