import Testing
@testable import Mercury

@Suite("Translation Runtime Policy")
struct TranslationRuntimePolicyTests {
    @Test("Decode translation run owner slot from owner slotKey")
    func decodeRunOwnerSlot() {
        let owner = AgentRunOwner(
            taskKind: .translation,
            entryId: 42,
            slotKey: "EN|hash-123|v1"
        )

        let slot = TranslationRuntimePolicy.decodeRunOwnerSlot(owner)
        #expect(slot?.entryId == 42)
        #expect(slot?.targetLanguage == "en")
        #expect(slot?.sourceContentHash == "hash-123")
        #expect(slot?.segmenterVersion == "v1")
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

    @Test("Decode returns nil for invalid slot format")
    func decodeRunOwnerSlotRejectsInvalidFormat() {
        let owner = AgentRunOwner(
            taskKind: .translation,
            entryId: 1,
            slotKey: "bad-format"
        )

        #expect(TranslationRuntimePolicy.decodeRunOwnerSlot(owner) == nil)
    }

    @Test("Auto enter bilingual only when current entry matches running translation owner")
    func shouldAutoEnterBilingual() {
        let runningOwner = AgentRunOwner(
            taskKind: .translation,
            entryId: 99,
            slotKey: "ja|hash|v1"
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
