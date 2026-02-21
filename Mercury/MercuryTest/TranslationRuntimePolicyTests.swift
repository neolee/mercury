import Testing
@testable import Mercury

@Suite("Translation Runtime Policy")
struct TranslationRuntimePolicyTests {
    @Test("Decode translation run owner slot from owner slotKey")
    func decodeRunOwnerSlot() {
        let owner = AgentRunOwner(
            taskKind: .translation,
            entryId: 42,
            slotKey: "en"
        )

        let slot = TranslationRuntimePolicy.decodeRunOwnerSlot(owner)
        #expect(slot?.entryId == 42)
        #expect(slot?.targetLanguage == "en")
    }

    @Test("Decode returns nil for non-translation owner")
    func decodeRunOwnerSlotRejectsNonTranslation() {
        let owner = AgentRunOwner(
            taskKind: .summary,
            entryId: 1,
            slotKey: "en|medium"
        )

        #expect(TranslationRuntimePolicy.decodeRunOwnerSlot(owner) == nil)
    }

    @Test("Decode normalizes unknown language code to english fallback")
    func decodeRunOwnerSlotNormalizesUnknownLanguage() {
        // Unknown language codes are normalized to English by AgentLanguageOption;
        // decodeRunOwnerSlot always returns a non-nil slot for translation owners.
        let owner = AgentRunOwner(
            taskKind: .translation,
            entryId: 1,
            slotKey: "xx-unknown"
        )
        let slot = TranslationRuntimePolicy.decodeRunOwnerSlot(owner)
        #expect(slot != nil)
        #expect(slot?.targetLanguage == AgentLanguageOption.english.code)
    }

    @Test("Auto enter bilingual only when current entry matches running translation owner")
    func shouldAutoEnterBilingual() {
        let runningOwner = AgentRunOwner(
            taskKind: .translation,
            entryId: 99,
            slotKey: "ja"
        )

        #expect(
            TranslationRuntimePolicy.shouldAutoEnterBilingual(
                currentEntryId: 99,
                runningOwner: runningOwner
            ) == true
        )
        #expect(
            TranslationRuntimePolicy.shouldAutoEnterBilingual(
                currentEntryId: 100,
                runningOwner: runningOwner
            ) == false
        )
        #expect(
            TranslationRuntimePolicy.shouldAutoEnterBilingual(
                currentEntryId: nil,
                runningOwner: runningOwner
            ) == false
        )
    }
}
