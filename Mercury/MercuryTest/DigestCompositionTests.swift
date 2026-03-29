import Foundation
import Testing
@testable import Mercury

@Suite("Digest Composition")
struct DigestCompositionTests {
    @Test("Resolved author falls back to feed title")
    func resolvedAuthorFallsBackToFeedTitle() {
        let author = DigestComposition.resolvedAuthor(entryAuthor: " ", feedTitle: "Feed Title")
        #expect(author == "Feed Title")
    }

    @Test("Resolved author prefers readability byline before feed title")
    func resolvedAuthorPrefersReadabilityBylineBeforeFeedTitle() {
        let author = DigestComposition.resolvedAuthor(
            entryAuthor: nil,
            readabilityByline: "Byline Author",
            feedTitle: "Feed Title"
        )
        #expect(author == "Byline Author")
    }

    @Test("Single entry share requires title and URL")
    func singleEntryShareRequiresTitleAndURL() {
        let entry = Entry(
            id: 1,
            feedId: 2,
            guid: nil,
            url: nil,
            title: "Title",
            author: nil,
            publishedAt: nil,
            summary: nil,
            isRead: false,
            isStarred: false,
            createdAt: Date()
        )

        #expect(DigestComposition.singleEntryTextShareContent(
            entry: entry,
            feedTitle: "Feed",
            noteText: nil,
            includeNote: false
        ) == nil)
    }

    @Test("Single entry share appends note when included")
    func singleEntryShareAppendsNoteWhenIncluded() {
        let entry = Entry(
            id: 1,
            feedId: 2,
            guid: nil,
            url: "https://example.com",
            title: "Title",
            author: "Author",
            publishedAt: nil,
            summary: nil,
            isRead: false,
            isStarred: false,
            createdAt: Date()
        )

        let content = DigestComposition.singleEntryTextShareContent(
            entry: entry,
            feedTitle: nil,
            noteText: "My note",
            includeNote: true
        )

        #expect(content == SingleEntryDigestTextShareContent(
            articleTitle: "Title",
            articleAuthor: "Author",
            articleURL: "https://example.com",
            noteText: "My note"
        ))
        #expect(content.map(DigestComposition.renderSingleEntryTextShareFallback) == "Title by Author https://example.com My note")
    }

    @Test("Single entry share omits by when resolved author is empty")
    func singleEntryShareOmitsByWhenResolvedAuthorIsEmpty() {
        let entry = Entry(
            id: 1,
            feedId: 2,
            guid: nil,
            url: "https://example.com",
            title: "Title",
            author: " ",
            publishedAt: nil,
            summary: nil,
            isRead: false,
            isStarred: false,
            createdAt: Date()
        )

        let content = DigestComposition.singleEntryTextShareContent(
            entry: entry,
            feedTitle: " ",
            noteText: nil,
            includeNote: false
        )

        #expect(content.map(DigestComposition.renderSingleEntryTextShareFallback) == "Title https://example.com")
    }

    @Test("Single entry share omits blank note content")
    func singleEntryShareOmitsBlankNoteContent() {
        let entry = Entry(
            id: 1,
            feedId: 2,
            guid: nil,
            url: "https://example.com",
            title: "Title",
            author: "Author",
            publishedAt: nil,
            summary: nil,
            isRead: false,
            isStarred: false,
            createdAt: Date()
        )

        let content = DigestComposition.singleEntryTextShareContent(
            entry: entry,
            feedTitle: nil,
            noteText: " \n ",
            includeNote: true
        )

        #expect(content.map(DigestComposition.renderSingleEntryTextShareFallback) == "Title by Author https://example.com")
    }
}
