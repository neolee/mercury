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

enum ReaderThemeQuickStylePresetID: String, Codable, CaseIterable {
    case none
    case warm
    case cool
    case slate
}

enum ReaderThemeFontFamilyOptionID: String, Codable, CaseIterable {
    case usePreset
    case systemSans
    case readingSerif
    case roundedSans
    case mono

    var cssValue: String? {
        switch self {
        case .usePreset:
            return nil
        case .systemSans:
            return "-apple-system, system-ui, \"SF Pro Text\", \"Helvetica Neue\", Helvetica, Arial, sans-serif"
        case .readingSerif:
            return "\"Iowan Old Style\", \"New York\", Charter, Georgia, \"Times New Roman\", serif"
        case .roundedSans:
            return "\"SF Pro Rounded\", \"Avenir Next\", \"Helvetica Neue\", Helvetica, Arial, sans-serif"
        case .mono:
            return "\"SF Mono\", Menlo, Monaco, Consolas, \"Liberation Mono\", \"Courier New\", monospace"
        }
    }
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

    init(
        fontFamilyBody: String? = nil,
        fontSizeBody: Double? = nil,
        lineHeightBody: Double? = nil,
        contentMaxWidth: Double? = nil,
        colorBackground: String? = nil,
        colorTextPrimary: String? = nil,
        colorTextSecondary: String? = nil,
        colorLink: String? = nil,
        colorBlockquoteBorder: String? = nil,
        colorCodeBackground: String? = nil,
        paragraphSpacing: Double? = nil,
        headingScale: Double? = nil,
        codeBlockRadius: Double? = nil
    ) {
        self.fontFamilyBody = fontFamilyBody
        self.fontSizeBody = fontSizeBody
        self.lineHeightBody = lineHeightBody
        self.contentMaxWidth = contentMaxWidth
        self.colorBackground = colorBackground
        self.colorTextPrimary = colorTextPrimary
        self.colorTextSecondary = colorTextSecondary
        self.colorLink = colorLink
        self.colorBlockquoteBorder = colorBlockquoteBorder
        self.colorCodeBackground = colorCodeBackground
        self.paragraphSpacing = paragraphSpacing
        self.headingScale = headingScale
        self.codeBlockRadius = codeBlockRadius
    }

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

    var expectedCacheThemeID: String {
        "\(presetID.rawValue):\(variant.rawValue):\(ReaderThemeFingerprint.fingerprint(tokens))"
    }

    var overrideHash: String {
        ReaderThemeFingerprint.fingerprint(tokens)
    }

    @discardableResult
    func debugAssertCacheIdentity(file: StaticString = #fileID, line: UInt = #line) -> Bool {
        let isValid = cacheThemeID == expectedCacheThemeID
        #if DEBUG
        if isValid == false {
            assertionFailure("Reader theme cache identity mismatch: \(cacheThemeID) vs \(expectedCacheThemeID)", file: file, line: line)
        }
        #endif
        return isValid
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

enum ReaderThemeQuickStylePreset {
    static func override(for presetID: ReaderThemeQuickStylePresetID, variant: ReaderThemeVariant) -> ReaderThemeOverride? {
        switch (presetID, variant) {
        case (.none, _):
            return nil
        case (.warm, .normal):
            return ReaderThemeOverride(
                colorBackground: "#f8f1e6",
                colorTextPrimary: "#3f2f22",
                colorTextSecondary: "#705b46",
                colorLink: "#8a4f16",
                colorBlockquoteBorder: "#d7c0a8",
                colorCodeBackground: "#efe2d2"
            )
        case (.warm, .dark):
            return ReaderThemeOverride(
                colorBackground: "#221a15",
                colorTextPrimary: "#ead8c5",
                colorTextSecondary: "#c6ad92",
                colorLink: "#deb37f",
                colorBlockquoteBorder: "#5f4b3d",
                colorCodeBackground: "#2c211a"
            )
        case (.cool, .normal):
            return ReaderThemeOverride(
                colorBackground: "#eaf4ff",
                colorTextPrimary: "#163047",
                colorTextSecondary: "#3e5a72",
                colorLink: "#005ea8",
                colorBlockquoteBorder: "#bfd8ef",
                colorCodeBackground: "#dcedff"
            )
        case (.cool, .dark):
            return ReaderThemeOverride(
                colorBackground: "#0f1f2e",
                colorTextPrimary: "#d7e9fb",
                colorTextSecondary: "#a3bfd8",
                colorLink: "#79b7f0",
                colorBlockquoteBorder: "#2f4f6a",
                colorCodeBackground: "#152a3c"
            )
        case (.slate, .normal):
            return ReaderThemeOverride(
                colorBackground: "#e6e7ea",
                colorTextPrimary: "#222429",
                colorTextSecondary: "#555a63",
                colorLink: "#6a5f8f",
                colorBlockquoteBorder: "#b8bbc3",
                colorCodeBackground: "#d7d9df"
            )
        case (.slate, .dark):
            return ReaderThemeOverride(
                colorBackground: "#1f2126",
                colorTextPrimary: "#e2e4e8",
                colorTextSecondary: "#b2b6bf",
                colorLink: "#b39ddb",
                colorBlockquoteBorder: "#4a4e57",
                colorCodeBackground: "#2a2d34"
            )
        }
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

enum ReaderThemeDebugValidation {
    static func validateContracts() {
        #if DEBUG
        precondition(ReaderThemePreset.isTokenPackComplete(), "Reader theme token pack is incomplete: \(ReaderThemePreset.missingTokenPackKeys())")

        for presetID in ReaderThemePresetID.allCases {
            for variant in ReaderThemeVariant.allCases {
                let baseTheme = EffectiveReaderTheme(
                    presetID: presetID,
                    variant: variant,
                    tokens: ReaderThemePreset.tokens(for: presetID, variant: variant)
                )
                precondition(baseTheme.debugAssertCacheIdentity(), "Reader theme cache identity must be internally consistent")

                let overriddenTheme = EffectiveReaderTheme(
                    presetID: presetID,
                    variant: variant,
                    tokens: baseTheme.tokens.applying(ReaderThemeOverride(fontSizeBody: baseTheme.tokens.fontSizeBody + 1))
                )
                precondition(overriddenTheme.debugAssertCacheIdentity(), "Reader theme override cache identity must be internally consistent")
                precondition(baseTheme.cacheThemeID != overriddenTheme.cacheThemeID, "Reader theme cache identity must change when tokens change")

                let duplicatedBaseTheme = EffectiveReaderTheme(
                    presetID: presetID,
                    variant: variant,
                    tokens: ReaderThemePreset.tokens(for: presetID, variant: variant)
                )
                precondition(baseTheme.cacheThemeID == duplicatedBaseTheme.cacheThemeID, "Reader theme cache identity must stay stable for same tokens")
            }
        }
        #endif
    }
}
