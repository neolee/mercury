import Testing
@testable import Mercury

@Suite("Summary Policy")
struct SummaryPolicyTests {
    @Test("Controls prefer running slot for selected entry")
    func controlsPreferRunningSlot() {
        let defaults = SummaryControlSelection(targetLanguage: "en", detailLevel: .medium)
        let running = SummaryRuntimeSlot(entryId: 10, targetLanguage: "ja", detailLevel: .detailed)
        let persisted = SummaryRuntimeSlot(entryId: 10, targetLanguage: "zh", detailLevel: .short)

        let resolved = SummaryPolicy.resolveControlSelection(
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

        let resolved = SummaryPolicy.resolveControlSelection(
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

        let resolved = SummaryPolicy.resolveControlSelection(
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
            SummaryPolicy.shouldMarkCurrentEntryPersistedOnCompletion(
                completedEntryId: 1,
                displayedEntryId: 1
            ) == true
        )
        #expect(
            SummaryPolicy.shouldMarkCurrentEntryPersistedOnCompletion(
                completedEntryId: 1,
                displayedEntryId: 2
            ) == false
        )
        #expect(
            SummaryPolicy.shouldMarkCurrentEntryPersistedOnCompletion(
                completedEntryId: 1,
                displayedEntryId: nil
            ) == false
        )
    }

    @Test("Waiting placeholder appears only when pending request exists and text is empty")
    func waitingPlaceholderRule() {
        #expect(
            SummaryPolicy.shouldShowWaitingPlaceholder(
                summaryTextIsEmpty: true,
                hasPendingRequestForSelectedEntry: true
            ) == true
        )
        #expect(
            SummaryPolicy.shouldShowWaitingPlaceholder(
                summaryTextIsEmpty: true,
                hasPendingRequestForSelectedEntry: false
            ) == false
        )
        #expect(
            SummaryPolicy.shouldShowWaitingPlaceholder(
                summaryTextIsEmpty: false,
                hasPendingRequestForSelectedEntry: true
            ) == false
        )
    }

    @Test("Auto run starts only when all constraints are satisfied")
    func autoRunStartRule() {
        #expect(
            SummaryPolicy.shouldStartAutoRunNow(
                autoEnabled: true,
                isSummaryRunning: false,
                hasPersistedSummaryForCurrentEntry: false,
                selectedEntryId: 10
            ) == true
        )
        #expect(
            SummaryPolicy.shouldStartAutoRunNow(
                autoEnabled: false,
                isSummaryRunning: false,
                hasPersistedSummaryForCurrentEntry: false,
                selectedEntryId: 10
            ) == false
        )
        #expect(
            SummaryPolicy.shouldStartAutoRunNow(
                autoEnabled: true,
                isSummaryRunning: true,
                hasPersistedSummaryForCurrentEntry: false,
                selectedEntryId: 10
            ) == false
        )
        #expect(
            SummaryPolicy.shouldStartAutoRunNow(
                autoEnabled: true,
                isSummaryRunning: false,
                hasPersistedSummaryForCurrentEntry: true,
                selectedEntryId: 10
            ) == false
        )
        #expect(
            SummaryPolicy.shouldStartAutoRunNow(
                autoEnabled: true,
                isSummaryRunning: false,
                hasPersistedSummaryForCurrentEntry: false,
                selectedEntryId: nil
            ) == false
        )
    }
}
