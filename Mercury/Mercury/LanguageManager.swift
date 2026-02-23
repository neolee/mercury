import Foundation
import SwiftUI

// MARK: - Language Manager

/// Global singleton responsible for resolving the active localization bundle.
///
/// All user-facing string lookups must go through `LanguageManager.shared.bundle`
/// rather than `Bundle.main` directly. This enables live language switching at
/// runtime without restarting the app.
///
/// See `docs/l10n.md` for the full design and usage guidelines.
@MainActor
@Observable
final class LanguageManager {

    // MARK: - Supported Languages

    struct SupportedLanguage: Identifiable {
        /// BCP-47 language code, e.g. "en", "zh-Hans".
        let code: String
        /// Display name shown as-is in the language picker; intentionally not localized.
        let displayName: String

        var id: String { code }
    }

    /// Ordered list of languages the app supports.
    /// To add a new language, append one entry here and add translations to `Localizable.xcstrings`.
    static let supported: [SupportedLanguage] = [
        .init(code: "en",      displayName: "English"),
        .init(code: "zh-Hans", displayName: "简体中文"),
    ]

    // MARK: - Singleton

    static let shared = LanguageManager()

    // MARK: - State

    /// The active localization bundle. All string lookups must use this bundle.
    private(set) var bundle: Bundle = .main

    /// The user's explicit language override (`nil` means follow the macOS system setting).
    private(set) var languageOverride: String?

    // MARK: - Init

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.userDefaultsKey)
        languageOverride = stored
        bundle = Self.resolveBundle(for: stored)
    }

    // MARK: - Public API

    /// Sets the app language. Pass `nil` to follow the macOS system setting.
    func setLanguage(_ code: String?) {
        languageOverride = code
        if let code {
            UserDefaults.standard.set(code, forKey: Self.userDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.userDefaultsKey)
        }
        bundle = Self.resolveBundle(for: code)
    }

    // MARK: - Bundle Resolution

    private static let userDefaultsKey = "App.language"

    /// A bundle backed by an empty temporary directory.
    ///
    /// Because there are no `Localizable.strings` files inside it, every call
    /// to `localizedString(forKey:value:table:)` returns the key itself — which
    /// is the English source text when using source-as-key `.xcstrings`.
    /// This is used instead of `Bundle.main` for the development language so
    /// that `Bundle.main`'s own preferred-localization resolution (which would
    /// otherwise pick `zh-Hans.lproj` as the only available lproj) is bypassed.
    private static let passthroughBundle: Bundle = {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-l10n-passthrough", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Bundle(url: dir) ?? .main
    }()

    /// Resolves the best matching `.lproj` bundle for the given language code.
    /// Falls back to the system preferred language, then to the passthrough bundle.
    private static func resolveBundle(for code: String?) -> Bundle {
        let candidates: [String]
        if let code {
            candidates = [code]
        } else {
            candidates = Locale.preferredLanguages
        }

        // The development language has no physical `.lproj` in the bundle because
        // Xcode's xcstrings pipeline uses source-as-key (keys = English strings).
        // We must return the passthrough bundle — not Bundle.main — to avoid
        // Bundle.main picking `zh-Hans.lproj` as its preferred localization when
        // that is the only `.lproj` present on disk.
        let devBase = String((Bundle.main.developmentLocalization ?? "en").prefix(2))

        for candidate in candidates {
            let base = String(candidate.prefix(2))

            if base == devBase {
                return passthroughBundle
            }

            // Non-development language: try exact match (e.g. "zh-Hans"), then base (e.g. "zh").
            for identifier in [candidate, base] {
                if let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
                   let lprojBundle = Bundle(path: path) {
                    return lprojBundle
                }
            }
        }

        return passthroughBundle
    }
}

// MARK: - SwiftUI Environment Key

private struct LocalizationBundleKey: EnvironmentKey {
    static let defaultValue: Bundle = .main
}

extension EnvironmentValues {
    /// The active localization bundle injected from the root of the SwiftUI view tree.
    ///
    /// Views read this value and pass it to every `Text("...", bundle: bundle)` call.
    /// Changing `LanguageManager.shared.bundle` causes `MercuryApp.body` to re-evaluate
    /// and propagate the new bundle down the entire view tree, achieving live switching.
    var localizationBundle: Bundle {
        get { self[LocalizationBundleKey.self] }
        set { self[LocalizationBundleKey.self] = newValue }
    }
}
