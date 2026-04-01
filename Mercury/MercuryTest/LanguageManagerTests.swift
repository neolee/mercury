import Foundation
import Testing
@testable import Mercury

@MainActor
@Suite("Language Manager")
struct LanguageManagerTests {
    @Test("Simplified Chinese variants normalize to zh-Hans")
    func simplifiedChineseVariantsNormalizeToSimplifiedChinese() {
        #expect(LanguageManager.normalizedSupportedLanguageCode(for: "zh-Hans") == "zh-Hans")
        #expect(LanguageManager.normalizedSupportedLanguageCode(for: "zh-Hans-CN") == "zh-Hans")
        #expect(LanguageManager.normalizedSupportedLanguageCode(for: "zh-CN") == "zh-Hans")
        #expect(LanguageManager.normalizedSupportedLanguageCode(for: "zh-SG") == "zh-Hans")
        #expect(LanguageManager.normalizedSupportedLanguageCode(for: "zh_Hans_SG") == "zh-Hans")
    }

    @Test("Traditional Chinese and unsupported languages do not normalize to zh-Hans")
    func nonSimplifiedChineseVariantsDoNotNormalizeToSimplifiedChinese() {
        #expect(LanguageManager.normalizedSupportedLanguageCode(for: "zh-Hant") == nil)
        #expect(LanguageManager.normalizedSupportedLanguageCode(for: "zh-HK") == nil)
        #expect(LanguageManager.normalizedSupportedLanguageCode(for: "ja-JP") == nil)
        #expect(LanguageManager.normalizedSupportedLanguageCode(for: "fr-FR") == nil)
    }

    @Test("System preferred language matching falls back to English for unsupported locales")
    func preferredLanguageMatchingFallsBackToEnglish() {
        #expect(LanguageManager.bestSupportedLanguageCode(for: ["zh-Hans-CN", "en-US"]) == "zh-Hans")
        #expect(LanguageManager.bestSupportedLanguageCode(for: ["zh-CN", "en-US"]) == "zh-Hans")
        #expect(LanguageManager.bestSupportedLanguageCode(for: ["zh-SG", "en-US"]) == "zh-Hans")
        #expect(LanguageManager.bestSupportedLanguageCode(for: ["zh-Hant", "en-US"]) == "en")
        #expect(LanguageManager.bestSupportedLanguageCode(for: ["ja-JP", "fr-FR"]) == "en")
    }

    @Test("Language override with zh-CN resolves to Simplified Chinese bundle")
    func simplifiedChineseOverrideResolvesToSimplifiedChineseBundle() {
        let originalOverride = LanguageManager.shared.languageOverride
        defer { LanguageManager.shared.setLanguage(originalOverride) }

        LanguageManager.shared.setLanguage("zh-CN")

        let localized = String(localized: "General", bundle: LanguageManager.shared.bundle)
        #expect(localized == "通用")
    }
}
