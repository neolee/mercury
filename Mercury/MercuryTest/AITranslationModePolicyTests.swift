import Testing
@testable import Mercury

@Suite("AI Translation Mode Policy")
struct AITranslationModePolicyTests {
    @Test("Toggle flips between original and bilingual")
    func toggleBehavior() {
        #expect(AITranslationModePolicy.toggledMode(from: .original) == .bilingual)
        #expect(AITranslationModePolicy.toggledMode(from: .bilingual) == .original)
    }

    @Test("Toolbar icon follows mode state")
    func toolbarIcon() {
        #expect(AITranslationModePolicy.toolbarButtonIconName(for: .original) == "globe")
        #expect(AITranslationModePolicy.toolbarButtonIconName(for: .bilingual) == "globe.badge.chevron.backward")
    }

    @Test("Toolbar visibility is reader-only")
    func toolbarVisibility() {
        #expect(AITranslationModePolicy.isToolbarButtonVisible(readingMode: .reader) == true)
        #expect(AITranslationModePolicy.isToolbarButtonVisible(readingMode: .web) == false)
        #expect(AITranslationModePolicy.isToolbarButtonVisible(readingMode: .dual) == false)
    }
}
