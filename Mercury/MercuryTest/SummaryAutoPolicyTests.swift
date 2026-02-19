import Testing
@testable import Mercury

@Suite("Summary Auto Policy")
struct SummaryAutoPolicyTests {
    @Test("Controls prefer running slot for selected entry")
    func controlsPreferRunningSlot() {
        let defaults = SummaryControlSelection(targetLanguage: "en", detailLevel: .medium)
        let running = SummaryRuntimeSlot(entryId: 10, targetLanguage: "ja", detailLevel: .detailed)
        let persisted = SummaryRuntimeSlot(entryId: 10, targetLanguage: "zh", detailLevel: .short)

        let resolved = SummaryAutoPolicy.resolveControlSelection(
            selectedEntryId: 10,
            runningSlot: running,
            latestPersistedSlot: persisted,
            defaults: defaults
        )

        #expect(resolved.targetLanguage == "ja")
        #expect(resolved.detailLevel == .detailed)
    }

    @Test("Controls fall back to latest persisted slot when no running slot")
    func controlsPreferPersistedSlot() {
        let defaults = SummaryControlSelection(targetLanguage: "en", detailLevel: .medium)
        let persisted = SummaryRuntimeSlot(entryId: 20, targetLanguage: "zh", detailLevel: .short)

        let resolved = SummaryAutoPolicy.resolveControlSelection(
            selectedEntryId: 20,
            runningSlot: nil,
            latestPersistedSlot: persisted,
            defaults: defaults
        )

        #expect(resolved.targetLanguage == "zh")
        #expect(resolved.detailLevel == .short)
    }

    @Test("Controls use defaults when no running and no persisted")
    func controlsUseDefaultsWhenEmpty() {
        let defaults = SummaryControlSelection(targetLanguage: "en", detailLevel: .medium)

        let resolved = SummaryAutoPolicy.resolveControlSelection(
            selectedEntryId: 1,
            runningSlot: nil,
            latestPersistedSlot: nil,
            defaults: defaults
        )

        #expect(resolved == defaults)
    }

    @Test("Completion marks persisted only for currently displayed entry")
    func completionMarkingRule() {
        #expect(
            SummaryAutoPolicy.shouldMarkCurrentEntryPersistedOnCompletion(
                completedEntryId: 1,
                displayedEntryId: 1
            ) == true
        )
        #expect(
            SummaryAutoPolicy.shouldMarkCurrentEntryPersistedOnCompletion(
                completedEntryId: 1,
                displayedEntryId: 2
            ) == false
        )
        #expect(
            SummaryAutoPolicy.shouldMarkCurrentEntryPersistedOnCompletion(
                completedEntryId: 1,
                displayedEntryId: nil
            ) == false
        )
    }

    @Test("Waiting placeholder appears only when other entry is running and text is empty")
    func waitingPlaceholderRule() {
        #expect(
            SummaryAutoPolicy.shouldShowWaitingPlaceholder(
                selectedEntryId: 2,
                runningEntryId: 1,
                summaryTextIsEmpty: true
            ) == true
        )
        #expect(
            SummaryAutoPolicy.shouldShowWaitingPlaceholder(
                selectedEntryId: 1,
                runningEntryId: 1,
                summaryTextIsEmpty: true
            ) == false
        )
        #expect(
            SummaryAutoPolicy.shouldShowWaitingPlaceholder(
                selectedEntryId: 2,
                runningEntryId: 1,
                summaryTextIsEmpty: false
            ) == false
        )
        #expect(
            SummaryAutoPolicy.shouldShowWaitingPlaceholder(
                selectedEntryId: nil,
                runningEntryId: 1,
                summaryTextIsEmpty: true
            ) == false
        )
    }

    @Test("Auto run starts only when all constraints are satisfied")
    func autoRunStartRule() {
        #expect(
            SummaryAutoPolicy.shouldStartAutoRunNow(
                autoEnabled: true,
                isSummaryRunning: false,
                hasPersistedSummaryForCurrentEntry: false,
                selectedEntryId: 10
            ) == true
        )
        #expect(
            SummaryAutoPolicy.shouldStartAutoRunNow(
                autoEnabled: false,
                isSummaryRunning: false,
                hasPersistedSummaryForCurrentEntry: false,
                selectedEntryId: 10
            ) == false
        )
        #expect(
            SummaryAutoPolicy.shouldStartAutoRunNow(
                autoEnabled: true,
                isSummaryRunning: true,
                hasPersistedSummaryForCurrentEntry: false,
                selectedEntryId: 10
            ) == false
        )
        #expect(
            SummaryAutoPolicy.shouldStartAutoRunNow(
                autoEnabled: true,
                isSummaryRunning: false,
                hasPersistedSummaryForCurrentEntry: true,
                selectedEntryId: 10
            ) == false
        )
        #expect(
            SummaryAutoPolicy.shouldStartAutoRunNow(
                autoEnabled: true,
                isSummaryRunning: false,
                hasPersistedSummaryForCurrentEntry: false,
                selectedEntryId: nil
            ) == false
        )
    }
}
