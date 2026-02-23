import Foundation
import Testing
@testable import Mercury

@Suite("MarkReadPolicy")
struct MarkReadPolicyTests {

    // MARK: - Helpers

    private func makeEntry(id: Int64, isRead: Bool) -> EntryListItem {
        EntryListItem(
            id: id,
            feedId: 1,
            title: "Test Entry",
            publishedAt: nil,
            createdAt: Date(),
            isRead: isRead,
            feedSourceTitle: nil
        )
    }

    // MARK: - selectionOutcome

    @Suite("selectionOutcome")
    struct SelectionOutcomeTests {
        @Test("Returns skipAutoMarkRead when new id matches auto-selected id")
        func skipWhenMatchesAutoSelected() {
            let outcome = MarkReadPolicy.selectionOutcome(newId: 1, autoSelectedId: 1)
            #expect(outcome == .skipAutoMarkRead)
        }

        @Test("Returns scheduleAutoMarkRead when auto-selected id is nil")
        func scheduleWhenAutoSelectedIsNil() {
            let outcome = MarkReadPolicy.selectionOutcome(newId: 1, autoSelectedId: nil)
            #expect(outcome == .scheduleAutoMarkRead)
        }

        @Test("Returns scheduleAutoMarkRead when new id differs from auto-selected id")
        func scheduleWhenDifferentEntry() {
            let outcome = MarkReadPolicy.selectionOutcome(newId: 2, autoSelectedId: 1)
            #expect(outcome == .scheduleAutoMarkRead)
        }
    }

    // MARK: - shouldExecuteAutoMarkRead

    @Suite("shouldExecuteAutoMarkRead")
    struct ShouldExecuteTests {
        @Test("Returns true when all conditions are met")
        func executesWhenAllConditionsMet() {
            #expect(
                MarkReadPolicy.shouldExecuteAutoMarkRead(
                    targetEntryId: 5,
                    currentSelectedEntryId: 5,
                    suppressedEntryId: nil,
                    isAlreadyRead: false
                )
            )
        }

        @Test("Returns false when user navigated away to another entry")
        func blockedByNavigation() {
            #expect(
                MarkReadPolicy.shouldExecuteAutoMarkRead(
                    targetEntryId: 5,
                    currentSelectedEntryId: 6,
                    suppressedEntryId: nil,
                    isAlreadyRead: false
                ) == false
            )
        }

        @Test("Returns false when user navigated away and selection is nil")
        func blockedBySelectionCleared() {
            #expect(
                MarkReadPolicy.shouldExecuteAutoMarkRead(
                    targetEntryId: 5,
                    currentSelectedEntryId: nil,
                    suppressedEntryId: nil,
                    isAlreadyRead: false
                ) == false
            )
        }

        @Test("Returns false when this entry is suppressed by manual mark-unread")
        func blockedBySuppression() {
            #expect(
                MarkReadPolicy.shouldExecuteAutoMarkRead(
                    targetEntryId: 5,
                    currentSelectedEntryId: 5,
                    suppressedEntryId: 5,
                    isAlreadyRead: false
                ) == false
            )
        }

        @Test("Returns false when entry was already marked read by another path")
        func blockedByAlreadyRead() {
            #expect(
                MarkReadPolicy.shouldExecuteAutoMarkRead(
                    targetEntryId: 5,
                    currentSelectedEntryId: 5,
                    suppressedEntryId: nil,
                    isAlreadyRead: true
                ) == false
            )
        }

        @Test("Suppression is scoped to the suppressed entry id only")
        func suppressionDoesNotAffectOtherEntry() {
            // Suppression for entry 99 must not block entry 5.
            #expect(
                MarkReadPolicy.shouldExecuteAutoMarkRead(
                    targetEntryId: 5,
                    currentSelectedEntryId: 5,
                    suppressedEntryId: 99,
                    isAlreadyRead: false
                )
            )
        }

        @Test("Returns false when both navigation and suppression block execution")
        func blockedByNavigationAndSuppression() {
            #expect(
                MarkReadPolicy.shouldExecuteAutoMarkRead(
                    targetEntryId: 5,
                    currentSelectedEntryId: 6,
                    suppressedEntryId: 5,
                    isAlreadyRead: false
                ) == false
            )
        }
    }

    // MARK: - canMarkRead

    @Suite("canMarkRead")
    struct CanMarkReadTests {
        @Test("Returns false when no entry is selected")
        func falseWhenNoSelection() {
            #expect(MarkReadPolicy.canMarkRead(selectedEntry: nil) == false)
        }

        @Test("Returns true when selected entry is unread")
        func trueForUnreadEntry() {
            let entry = EntryListItem(
                id: 1, feedId: 1, title: nil, publishedAt: nil,
                createdAt: Date(), isRead: false, feedSourceTitle: nil
            )
            #expect(MarkReadPolicy.canMarkRead(selectedEntry: entry))
        }

        @Test("Returns false when selected entry is already read")
        func falseForReadEntry() {
            let entry = EntryListItem(
                id: 1, feedId: 1, title: nil, publishedAt: nil,
                createdAt: Date(), isRead: true, feedSourceTitle: nil
            )
            #expect(MarkReadPolicy.canMarkRead(selectedEntry: entry) == false)
        }
    }

    // MARK: - canMarkUnread

    @Suite("canMarkUnread")
    struct CanMarkUnreadTests {
        @Test("Returns false when no entry is selected")
        func falseWhenNoSelection() {
            #expect(MarkReadPolicy.canMarkUnread(selectedEntry: nil) == false)
        }

        @Test("Returns true when selected entry is already read")
        func trueForReadEntry() {
            let entry = EntryListItem(
                id: 1, feedId: 1, title: nil, publishedAt: nil,
                createdAt: Date(), isRead: true, feedSourceTitle: nil
            )
            #expect(MarkReadPolicy.canMarkUnread(selectedEntry: entry))
        }

        @Test("Returns false when selected entry is unread")
        func falseForUnreadEntry() {
            let entry = EntryListItem(
                id: 1, feedId: 1, title: nil, publishedAt: nil,
                createdAt: Date(), isRead: false, feedSourceTitle: nil
            )
            #expect(MarkReadPolicy.canMarkUnread(selectedEntry: entry) == false)
        }
    }

    // MARK: - canMarkRead and canMarkUnread are mutually exclusive

    @Test("canMarkRead and canMarkUnread are always mutually exclusive for any entry")
    func mutualExclusion() {
        let unread = EntryListItem(
            id: 1, feedId: 1, title: nil, publishedAt: nil,
            createdAt: Date(), isRead: false, feedSourceTitle: nil
        )
        let read = EntryListItem(
            id: 2, feedId: 1, title: nil, publishedAt: nil,
            createdAt: Date(), isRead: true, feedSourceTitle: nil
        )
        // For an unread entry exactly one of the two is true.
        #expect(MarkReadPolicy.canMarkRead(selectedEntry: unread) == true)
        #expect(MarkReadPolicy.canMarkUnread(selectedEntry: unread) == false)
        // For a read entry exactly one of the two is true.
        #expect(MarkReadPolicy.canMarkRead(selectedEntry: read) == false)
        #expect(MarkReadPolicy.canMarkUnread(selectedEntry: read) == true)
        // For no selection both are false.
        #expect(MarkReadPolicy.canMarkRead(selectedEntry: nil) == false)
        #expect(MarkReadPolicy.canMarkUnread(selectedEntry: nil) == false)
    }
}
