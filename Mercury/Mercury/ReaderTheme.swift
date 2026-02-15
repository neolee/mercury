import Foundation

enum ReaderThemePresetID: String, Codable, CaseIterable {
    case classic
    case paper
}

enum ReaderThemeMode: String, Codable, CaseIterable {
    case auto
    case forceLight
    case forceDark
}

enum ReaderThemeVariant: String, Codable {
    case normal
    case dark

    static let allCases: [ReaderThemeVariant] = [.normal, .dark]
}

struct ReaderThemeTokens: Codable, Hashable {
    var fontFamilyBody: String
    var fontSizeBody: Double
    var lineHeightBody: Double
    var contentMaxWidth: Double

    var colorBackground: String
    var colorTextPrimary: String
    var colorTextSecondary: String
    var colorLink: String
    var colorBlockquoteBorder: String
    var colorCodeBackground: String

    var paragraphSpacing: Double
    var headingScale: Double
    var codeBlockRadius: Double

    func applying(_ override: ReaderThemeOverride?) -> ReaderThemeTokens {
        guard let override else { return self }
        return ReaderThemeTokens(
            fontFamilyBody: override.fontFamilyBody ?? fontFamilyBody,
            fontSizeBody: override.fontSizeBody ?? fontSizeBody,
            lineHeightBody: override.lineHeightBody ?? lineHeightBody,
            contentMaxWidth: override.contentMaxWidth ?? contentMaxWidth,
            colorBackground: override.colorBackground ?? colorBackground,
            colorTextPrimary: override.colorTextPrimary ?? colorTextPrimary,
            colorTextSecondary: override.colorTextSecondary ?? colorTextSecondary,
            colorLink: override.colorLink ?? colorLink,
            colorBlockquoteBorder: override.colorBlockquoteBorder ?? colorBlockquoteBorder,
            colorCodeBackground: override.colorCodeBackground ?? colorCodeBackground,
            paragraphSpacing: override.paragraphSpacing ?? paragraphSpacing,
            headingScale: override.headingScale ?? headingScale,
            codeBlockRadius: override.codeBlockRadius ?? codeBlockRadius
        )
    }
}

struct ReaderThemeOverride: Codable, Hashable {
    var fontFamilyBody: String?
    var fontSizeBody: Double?
    var lineHeightBody: Double?
    var contentMaxWidth: Double?

    var colorBackground: String?
    var colorTextPrimary: String?
    var colorTextSecondary: String?
    var colorLink: String?
    var colorBlockquoteBorder: String?
    var colorCodeBackground: String?

    var paragraphSpacing: Double?
    var headingScale: Double?
    var codeBlockRadius: Double?

    static let empty = ReaderThemeOverride()

    var isEmpty: Bool {
        self == .empty
    }
}

struct EffectiveReaderTheme: Hashable {
    var presetID: ReaderThemePresetID
    var variant: ReaderThemeVariant
    var tokens: ReaderThemeTokens

    var cacheThemeID: String {
        "\(presetID.rawValue):\(variant.rawValue):\(overrideHash)"
    }

    var overrideHash: String {
        ReaderThemeFingerprint.fingerprint(tokens)
    }
}

enum ReaderThemeResolver {
    static func resolveVariant(mode: ReaderThemeMode, isSystemDark: Bool) -> ReaderThemeVariant {
        switch mode {
        case .auto:
            return isSystemDark ? .dark : .normal
        case .forceLight:
            return .normal
        case .forceDark:
            return .dark
        }
    }

    static func resolve(
        presetID: ReaderThemePresetID,
        mode: ReaderThemeMode,
        isSystemDark: Bool,
        override: ReaderThemeOverride?
    ) -> EffectiveReaderTheme {
        let variant = resolveVariant(mode: mode, isSystemDark: isSystemDark)
        let presetTokens = ReaderThemePreset.tokens(for: presetID, variant: variant)
        let merged = presetTokens.applying(override)
        return EffectiveReaderTheme(presetID: presetID, variant: variant, tokens: merged)
    }
}

enum ReaderThemePreset {
    static func tokens(for presetID: ReaderThemePresetID, variant: ReaderThemeVariant) -> ReaderThemeTokens {
        let key = ReaderThemePresetKey(presetID: presetID, variant: variant)
        guard let tokens = tokenPacks[key] else {
            preconditionFailure("Missing token pack for \(presetID.rawValue).\(variant.rawValue)")
        }
        return tokens
    }

    static func isTokenPackComplete() -> Bool {
        ReaderThemePresetID.allCases.allSatisfy { presetID in
            ReaderThemeVariant.allCases.allSatisfy { variant in
                tokenPacks[ReaderThemePresetKey(presetID: presetID, variant: variant)] != nil
            }
        }
    }

    static func missingTokenPackKeys() -> [String] {
        var missing: [String] = []
        for presetID in ReaderThemePresetID.allCases {
            for variant in ReaderThemeVariant.allCases {
                let key = ReaderThemePresetKey(presetID: presetID, variant: variant)
                if tokenPacks[key] == nil {
                    missing.append("\(presetID.rawValue).\(variant.rawValue)")
                }
            }
        }
        return missing
    }

    private static let tokenPacks: [ReaderThemePresetKey: ReaderThemeTokens] = [
        ReaderThemePresetKey(presetID: .classic, variant: .normal): classicNormal,
        ReaderThemePresetKey(presetID: .classic, variant: .dark): classicDark,
        ReaderThemePresetKey(presetID: .paper, variant: .normal): paperNormal,
        ReaderThemePresetKey(presetID: .paper, variant: .dark): paperDark
    ]

    private static let classicNormal = ReaderThemeTokens(
        fontFamilyBody: "-apple-system, system-ui, \"SF Pro Text\", \"Helvetica Neue\", Helvetica, Arial, sans-serif",
        fontSizeBody: 17,
        lineHeightBody: 1.65,
        contentMaxWidth: 760,
        colorBackground: "#ffffff",
        colorTextPrimary: "#1a1a1a",
        colorTextSecondary: "#555555",
        colorLink: "#0a66cc",
        colorBlockquoteBorder: "#dddddd",
        colorCodeBackground: "#f6f6f6",
        paragraphSpacing: 1,
        headingScale: 1,
        codeBlockRadius: 8
    )

    private static let classicDark = ReaderThemeTokens(
        fontFamilyBody: "-apple-system, system-ui, \"SF Pro Text\", \"Helvetica Neue\", Helvetica, Arial, sans-serif",
        fontSizeBody: 17,
        lineHeightBody: 1.65,
        contentMaxWidth: 760,
        colorBackground: "#121212",
        colorTextPrimary: "#e6e6e6",
        colorTextSecondary: "#bdbdbd",
        colorLink: "#8ab4f8",
        colorBlockquoteBorder: "#333333",
        colorCodeBackground: "#1e1e1e",
        paragraphSpacing: 1,
        headingScale: 1,
        codeBlockRadius: 8
    )

    private static let paperNormal = ReaderThemeTokens(
        fontFamilyBody: "-apple-system, system-ui, \"SF Pro Text\", \"Helvetica Neue\", Helvetica, Arial, sans-serif",
        fontSizeBody: 18,
        lineHeightBody: 1.72,
        contentMaxWidth: 760,
        colorBackground: "#f5efe6",
        colorTextPrimary: "#3b2f24",
        colorTextSecondary: "#6b5b4b",
        colorLink: "#7a4f16",
        colorBlockquoteBorder: "#d3c3b4",
        colorCodeBackground: "#efe5d8",
        paragraphSpacing: 1.05,
        headingScale: 1,
        codeBlockRadius: 8
    )

    private static let paperDark = ReaderThemeTokens(
        fontFamilyBody: "-apple-system, system-ui, \"SF Pro Text\", \"Helvetica Neue\", Helvetica, Arial, sans-serif",
        fontSizeBody: 18,
        lineHeightBody: 1.72,
        contentMaxWidth: 760,
        colorBackground: "#1f1a16",
        colorTextPrimary: "#e8dccf",
        colorTextSecondary: "#bfae9a",
        colorLink: "#d8b07a",
        colorBlockquoteBorder: "#5a4a3c",
        colorCodeBackground: "#2a221c",
        paragraphSpacing: 1.05,
        headingScale: 1,
        codeBlockRadius: 8
    )
}

private struct ReaderThemePresetKey: Hashable {
    var presetID: ReaderThemePresetID
    var variant: ReaderThemeVariant
}

private enum ReaderThemeFingerprint {
    static func fingerprint(_ tokens: ReaderThemeTokens) -> String {
        let payload = [
            tokens.fontFamilyBody,
            String(tokens.fontSizeBody),
            String(tokens.lineHeightBody),
            String(tokens.contentMaxWidth),
            tokens.colorBackground,
            tokens.colorTextPrimary,
            tokens.colorTextSecondary,
            tokens.colorLink,
            tokens.colorBlockquoteBorder,
            tokens.colorCodeBackground,
            String(tokens.paragraphSpacing),
            String(tokens.headingScale),
            String(tokens.codeBlockRadius)
        ].joined(separator: "|")

        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in payload.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }
}
