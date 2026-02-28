import Foundation

struct AgentLanguageOption: Identifiable, Hashable, Sendable {
    let code: String
    let nativeName: String
    let englishName: String

    var id: String { code }

    nonisolated static let english = AgentLanguageOption(code: "en", nativeName: "English", englishName: "English")

    nonisolated static let supported: [AgentLanguageOption] = [
        english,
        AgentLanguageOption(code: "zh-Hans", nativeName: "中文（简体）", englishName: "Chinese (Simplified)"),
        AgentLanguageOption(code: "zh-Hant", nativeName: "中文（繁体）", englishName: "Chinese (Traditional)"),
        AgentLanguageOption(code: "ja", nativeName: "日本語", englishName: "Japanese"),
        AgentLanguageOption(code: "ko", nativeName: "한국어", englishName: "Korean"),
        AgentLanguageOption(code: "es", nativeName: "Español", englishName: "Spanish"),
        AgentLanguageOption(code: "fr", nativeName: "Français", englishName: "French"),
        AgentLanguageOption(code: "de", nativeName: "Deutsch", englishName: "German"),
        AgentLanguageOption(code: "pt-BR", nativeName: "Português (Brasil)", englishName: "Portuguese (Brazil)"),
        AgentLanguageOption(code: "ru", nativeName: "Русский", englishName: "Russian"),
        AgentLanguageOption(code: "ar", nativeName: "العربية", englishName: "Arabic"),
        AgentLanguageOption(code: "hi", nativeName: "हिन्दी", englishName: "Hindi")
    ]

    nonisolated static func normalizeCode(_ rawCode: String) -> String {
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

    nonisolated static func option(for code: String) -> AgentLanguageOption {
        let normalized = normalizeCode(code)
        return supported.first(where: { $0.code.caseInsensitiveCompare(normalized) == .orderedSame }) ?? english
    }

    nonisolated private static let canonicalMap: [String: String] = [
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


