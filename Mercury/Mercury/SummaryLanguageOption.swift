import Foundation

struct SummaryLanguageOption: Identifiable, Hashable, Sendable {
    let code: String
    let nativeName: String
    let englishName: String

    var id: String { code }

    static let english = SummaryLanguageOption(code: "en", nativeName: "English", englishName: "English")

    static let supported: [SummaryLanguageOption] = [
        english,
        SummaryLanguageOption(code: "zh-Hans", nativeName: "中文（简体）", englishName: "Chinese (Simplified)"),
        SummaryLanguageOption(code: "zh-Hant", nativeName: "中文（繁体）", englishName: "Chinese (Traditional)"),
        SummaryLanguageOption(code: "ja", nativeName: "日本語", englishName: "Japanese"),
        SummaryLanguageOption(code: "ko", nativeName: "한국어", englishName: "Korean"),
        SummaryLanguageOption(code: "es", nativeName: "Español", englishName: "Spanish"),
        SummaryLanguageOption(code: "fr", nativeName: "Français", englishName: "French"),
        SummaryLanguageOption(code: "de", nativeName: "Deutsch", englishName: "German"),
        SummaryLanguageOption(code: "pt-BR", nativeName: "Português (Brasil)", englishName: "Portuguese (Brazil)"),
        SummaryLanguageOption(code: "ru", nativeName: "Русский", englishName: "Russian"),
        SummaryLanguageOption(code: "ar", nativeName: "العربية", englishName: "Arabic"),
        SummaryLanguageOption(code: "hi", nativeName: "हिन्दी", englishName: "Hindi")
    ]

    static func normalizeCode(_ rawCode: String) -> String {
        let trimmed = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return english.code
        }

        let canonical = canonicalMap[trimmed.lowercased()] ?? trimmed
        if supported.contains(where: { $0.code.caseInsensitiveCompare(canonical) == .orderedSame }) {
            return canonical
        }
        return english.code
    }

    static func option(for code: String) -> SummaryLanguageOption {
        let normalized = normalizeCode(code)
        return supported.first(where: { $0.code.caseInsensitiveCompare(normalized) == .orderedSame }) ?? english
    }

    private static let canonicalMap: [String: String] = [
        "en-us": "en",
        "en-gb": "en",
        "zh": "zh-Hans",
        "zh-cn": "zh-Hans",
        "zh-sg": "zh-Hans",
        "zh-hk": "zh-Hant",
        "zh-tw": "zh-Hant",
        "pt": "pt-BR",
        "pt-br": "pt-BR"
    ]
}

