import Testing
@testable import Mercury

@Suite("AI Translation Mode Policy")
struct TranslationModePolicyTests {
    @Test("Toggle flips between original and bilingual")
    func toggleBehavior() {
        #expect(TranslationModePolicy.toggledMode(from: .original) == .bilingual)
        #expect(TranslationModePolicy.toggledMode(from: .bilingual) == .original)
    }

    @Test("Toolbar icon follows mode state")
    func toolbarIcon() {
        #expect(TranslationModePolicy.toolbarButtonIconName(for: .original) == "globe")
        #expect(TranslationModePolicy.toolbarButtonIconName(for: .bilingual) == "globe.badge.chevron.backward")
    }

    @Test("Toolbar visibility is reader-only")
    func toolbarVisibility() {
        #expect(TranslationModePolicy.isToolbarButtonVisible(readingMode: .reader) == true)
        #expect(TranslationModePolicy.isToolbarButtonVisible(readingMode: .web) == false)
        #expect(TranslationModePolicy.isToolbarButtonVisible(readingMode: .dual) == false)
    }
}
