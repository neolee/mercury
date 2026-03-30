import Foundation
import Testing
@testable import Mercury

@Suite("Digest Export Policy")
struct DigestExportPolicyTests {
    @Test("Single entry filename uses export date and slug")
    func singleEntryFilenameUsesExportDateAndSlug() {
        let date = Date(timeIntervalSince1970: 1_774_742_400) // 2026-03-29 00:00:00 UTC
        let fileName = DigestExportPolicy.makeSingleEntryFileName(
            digestTitle: "Reader Pipeline Debugging",
            exportDate: date
        )

        #expect(fileName == "2026-03-29-reader-pipeline-debugging.md")
    }

    @Test("Multiple entry filename and digest title use fixed export baseline")
    func multipleEntryFilenameAndDigestTitleUseFixedExportBaseline() {
        let date = Date(timeIntervalSince1970: 1_774_828_800) // 2026-03-30 00:00:00 UTC

        let fileName = DigestExportPolicy.makeMultipleEntryFileName(exportDate: date)
        let fileSlug = DigestExportPolicy.makeMultipleEntryFileSlug(exportDate: date)
        let digestTitle = DigestExportPolicy.makeMultipleEntryDigestTitle(exportDate: date)

        #expect(fileName == "2026-03-30-digest.md")
        #expect(fileSlug == "2026-03-30-digest")
        #expect(digestTitle == "推荐阅读（2026年03月30日）")
    }

    @Test("Slug normalization preserves CJK and removes hostile characters")
    func slugNormalizationPreservesCJKAndRemovesHostileCharacters() {
        let slug = DigestExportPolicy.makeSingleEntryFileSlug(title: " 数据库 / 缓存: 设计? ")
        #expect(slug == "数据库-缓存-设计")
    }

    @Test("Unique file URL appends numeric suffix on collision")
    func uniqueFileURLAppendsNumericSuffixOnCollision() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DigestExportPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = directory.appendingPathComponent("2026-03-29-digest.md")
        let secondURL = directory.appendingPathComponent("2026-03-29-digest-2.md")
        try "one".write(to: firstURL, atomically: true, encoding: .utf8)
        try "two".write(to: secondURL, atomically: true, encoding: .utf8)

        let resolved = DigestExportPolicy.uniqueFileURL(
            in: directory,
            preferredFileName: "2026-03-29-digest.md"
        )

        #expect(resolved.lastPathComponent == "2026-03-29-digest-3.md")
    }

    @Test("Markdown layout normalization collapses extra blank lines between sections")
    func markdownLayoutNormalizationCollapsesExtraBlankLinesBetweenSections() {
        let markdown = """
        **Source**: [Article](https://example.com)
        **Author**: Author


        > Summary



        **My Take**: Thought
        """

        let normalized = DigestExportPolicy.normalizeMarkdownLayout(markdown)

        #expect(normalized == """
        **Source**: [Article](https://example.com)
        **Author**: Author

        > Summary

        **My Take**: Thought
        """)
    }

    @Test("Multiple entry content only keeps optional sections when enabled")
    func multipleEntryContentKeepsOptionalSectionsOnlyWhenEnabled() {
        let date = Date(timeIntervalSince1970: 1_774_828_800)
        let entries = [
            DigestMultipleEntryMarkdownEntryContent(
                articleTitle: "Entry One",
                articleAuthor: "Neo",
                articleURL: "https://example.com/1",
                summaryText: "Summary One",
                noteText: "Note One"
            ),
            DigestMultipleEntryMarkdownEntryContent(
                articleTitle: "Entry Two",
                articleAuthor: "Neo",
                articleURL: "https://example.com/2",
                summaryText: nil,
                noteText: nil
            )
        ]

        let withoutOptional = DigestExportPolicy.makeMultipleEntryMarkdownContent(
            entries: entries,
            includeSummary: false,
            includeNote: false,
            exportDate: date
        )
        let withOptional = DigestExportPolicy.makeMultipleEntryMarkdownContent(
            entries: entries,
            includeSummary: true,
            includeNote: true,
            exportDate: date
        )

        #expect(withoutOptional?.entries.first?.summaryText == nil)
        #expect(withoutOptional?.entries.first?.noteText == nil)
        #expect(withOptional?.entries.first?.summaryText == "Summary One")
        #expect(withOptional?.entries.first?.noteText == "Note One")
        #expect(withOptional?.entries.last?.summaryText == nil)
        #expect(withOptional?.entries.last?.noteText == nil)
    }
}
