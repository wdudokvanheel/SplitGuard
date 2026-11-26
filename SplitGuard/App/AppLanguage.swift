// SPDX-License-Identifier: MIT

import Foundation
import Observation
import os
import SplitGuardCore

enum AppLanguage: String, CaseIterable, Identifiable, Hashable, Sendable {
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case dutch = "nl"

    static let defaultsKey = "splitguard.language"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .english:
            return "English"
        case .spanish:
            return "Español"
        case .french:
            return "Français"
        case .german:
            return "Deutsch"
        case .dutch:
            return "Nederlands"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    static func resolveSystemDefault(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        for identifier in preferredLanguages {
            guard let code = extractLanguageCode(from: identifier),
                  let language = AppLanguage(rawValue: code) else {
                continue
            }
            return language
        }
        return .english
    }

    static func load(
        from userDefaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        if let rawValue = userDefaults.string(forKey: defaultsKey),
           let language = AppLanguage(rawValue: rawValue) {
            return language
        }
        return resolveSystemDefault(preferredLanguages: preferredLanguages)
    }

    func save(
        to userDefaults: UserDefaults = .standard,
        sharedDefaults: UserDefaults? = AppLanguage.sharedGroupDefaults()
    ) {
        userDefaults.set(rawValue, forKey: Self.defaultsKey)
        sharedDefaults?.set(rawValue, forKey: Self.defaultsKey)
    }

    static func sharedGroupDefaults() -> UserDefaults? {
        guard let groupID = AppGroup.identifier() else { return nil }
        return UserDefaults(suiteName: groupID)
    }

    private static func extractLanguageCode(from identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: "_", with: "-")
        if let primary = normalized.split(separator: "-").first, !primary.isEmpty {
            return primary.lowercased()
        }
        return Locale(identifier: trimmed).language.languageCode?.identifier.lowercased()
    }
}

enum AppLocalization {
    @MainActor
    @Observable
    final class State {
        static let shared = State()

        var language: AppLanguage

        private init() {
            let initial = AppLanguage.load()
            self.language = initial
            AppLocalization.lockedLanguage.withLock { $0 = initial }
        }
    }

    private static let lockedLanguage = OSAllocatedUnfairLock<AppLanguage>(
        initialState: AppLanguage.load()
    )
    private static let cachedBundles = OSAllocatedUnfairLock<[String: Bundle]>(
        initialState: [:]
    )

    static var currentLanguage: AppLanguage {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                State.shared.language
            }
        }
        return lockedLanguage.withLock { $0 }
    }

    static var currentLocale: Locale {
        currentLanguage.locale
    }

    static func setLanguage(_ language: AppLanguage) {
        lockedLanguage.withLock { $0 = language }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if State.shared.language != language {
                    State.shared.language = language
                }
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if State.shared.language != language {
                        State.shared.language = language
                    }
                }
            }
        }
    }

    static func bundle(for language: AppLanguage, in baseBundle: Bundle = .main) -> Bundle {
        let cacheKey = "\(baseBundle.bundlePath)::\(language.rawValue)"
        if let cached = cachedBundles.withLock({ $0[cacheKey] }) {
            return cached
        }
        let resolved: Bundle
        if let path = baseBundle.path(forResource: language.rawValue, ofType: "lproj"),
           let localizedBundle = Bundle(path: path) {
            resolved = localizedBundle
        } else if let englishPath = baseBundle.path(forResource: AppLanguage.english.rawValue, ofType: "lproj"),
                  let englishBundle = Bundle(path: englishPath) {
            resolved = englishBundle
        } else {
            resolved = baseBundle
        }
        cachedBundles.withLock { $0[cacheKey] = resolved }
        return resolved
    }
}

enum L10n {
    static func tr(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        language: AppLanguage? = nil,
        bundle baseBundle: Bundle = .main
    ) -> String {
        let active = language ?? AppLocalization.currentLanguage
        let targetBundle = AppLocalization.bundle(for: active, in: baseBundle)
        return String(
            localized: key,
            defaultValue: defaultValue,
            table: nil,
            bundle: targetBundle,
            locale: active.locale,
            comment: ""
        )
    }
}
