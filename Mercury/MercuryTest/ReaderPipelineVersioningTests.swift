//
//  ReaderPipelineVersioningTests.swift
//  MercuryTest
//

import XCTest
@testable import Mercury

final class ReaderPipelineVersioningTests: XCTestCase {

    // MARK: - Version constants are positive

    func test_versionConstants_arePositive() {
        XCTAssertGreaterThan(ReaderPipelineVersion.readability, 0)
        XCTAssertGreaterThan(ReaderPipelineVersion.markdown, 0)
        XCTAssertGreaterThan(ReaderPipelineVersion.readerRender, 0)
    }

    // MARK: - serveCachedHTML: all layers current

    func test_allLayersCurrent_servesCachedHTML() {
        let state = makeState(
            hasCachedHTML: true,
            cachedHTMLVersion: ReaderPipelineVersion.readerRender,
            hasMarkdown: true,
            markdownVersion: ReaderPipelineVersion.markdown,
            hasCleanedHtml: true,
            readabilityVersion: ReaderPipelineVersion.readability,
            hasSourceHtml: true
        )
        XCTAssertEqual(ReaderRebuildPolicy.action(for: state), .serveCachedHTML)
    }

    func test_cacheCurrentButMarkdownStale_rebuildsMarkdown() {
        // Render cache cannot be reused when the upstream Markdown layer is stale.
        let state = makeState(
            hasCachedHTML: true,
            cachedHTMLVersion: ReaderPipelineVersion.readerRender,
            hasMarkdown: true,
            markdownVersion: ReaderPipelineVersion.markdown - 1,
            hasCleanedHtml: true,
            readabilityVersion: ReaderPipelineVersion.readability,
            hasSourceHtml: true
        )
        XCTAssertEqual(ReaderRebuildPolicy.action(for: state), .rebuildMarkdownAndRender)
    }

    // MARK: - rerenderFromMarkdown: render stale, markdown current

    func test_renderStalePresentMarkdownCurrent_rerenders() {
        let state = makeState(
            hasCachedHTML: true,
            cachedHTMLVersion: ReaderPipelineVersion.readerRender - 1,
            hasMarkdown: true,
            markdownVersion: ReaderPipelineVersion.markdown,
            hasCleanedHtml: true,
            readabilityVersion: ReaderPipelineVersion.readability
        )
        XCTAssertEqual(ReaderRebuildPolicy.action(for: state), .rerenderFromMarkdown)
    }

    func test_noCachedHTML_markdownCurrent_rerenders() {
        let state = makeState(
            hasCachedHTML: false,
            hasMarkdown: true,
            markdownVersion: ReaderPipelineVersion.markdown,
            hasCleanedHtml: true,
            readabilityVersion: ReaderPipelineVersion.readability
        )
        XCTAssertEqual(ReaderRebuildPolicy.action(for: state), .rerenderFromMarkdown)
    }

    func test_nilCachedHTMLVersion_markdownCurrent_rerenders() {
        // nil cache version == version 0, which mismatches current >= 1.
        let state = makeState(
            hasCachedHTML: true,
            cachedHTMLVersion: nil,
            hasMarkdown: true,
            markdownVersion: ReaderPipelineVersion.markdown,
            hasCleanedHtml: true,
            readabilityVersion: ReaderPipelineVersion.readability
        )
        XCTAssertEqual(ReaderRebuildPolicy.action(for: state), .rerenderFromMarkdown)
    }

    // MARK: - rebuildMarkdownAndRender: markdown stale, cleanedHtml current

    func test_markdownStale_cleanedHtmlCurrent_rebuildsMarkdown() {
        let state = makeState(
            hasCachedHTML: false,
            hasMarkdown: true,
            markdownVersion: ReaderPipelineVersion.markdown - 1,
            hasCleanedHtml: true,
            readabilityVersion: ReaderPipelineVersion.readability
        )
        XCTAssertEqual(ReaderRebuildPolicy.action(for: state), .rebuildMarkdownAndRender)
    }

    func test_noMarkdown_cleanedHtmlCurrent_rebuildsMarkdown() {
        let state = makeState(
            hasCachedHTML: false,
            hasMarkdown: false,
            hasCleanedHtml: true,
            readabilityVersion: ReaderPipelineVersion.readability
        )
        XCTAssertEqual(ReaderRebuildPolicy.action(for: state), .rebuildMarkdownAndRender)
    }

    func test_nilMarkdownVersion_cleanedHtmlCurrent_rebuildsMarkdown() {
        let state = makeState(
            hasCachedHTML: false,
            hasMarkdown: true,
            markdownVersion: nil,
            hasCleanedHtml: true,
            readabilityVersion: ReaderPipelineVersion.readability
        )
        XCTAssertEqual(ReaderRebuildPolicy.action(for: state), .rebuildMarkdownAndRender)
    }

    // MARK: - rerunReadabilityAndRebuild: cleanedHtml stale, sourceHtml present

    func test_cleanedHtmlStale_sourceHtmlPresent_rerunsReadability() {
        let state = makeState(
            hasCachedHTML: false,
            hasMarkdown: false,
            hasCleanedHtml: true,
            readabilityVersion: ReaderPipelineVersion.readability - 1,
            hasSourceHtml: true
        )
        XCTAssertEqual(ReaderRebuildPolicy.action(for: state), .rerunReadabilityAndRebuild)
    }

    func test_noCleanedHtml_sourceHtmlPresent_rerunsReadability() {
        let state = makeState(
            hasCachedHTML: false,
            hasMarkdown: false,
            hasCleanedHtml: false,
            hasSourceHtml: true
        )
        XCTAssertEqual(ReaderRebuildPolicy.action(for: state), .rerunReadabilityAndRebuild)
    }

    func test_nilReadabilityVersion_sourceHtmlPresent_rerunsReadability() {
        let state = makeState(
            hasCachedHTML: false,
            hasMarkdown: false,
            hasCleanedHtml: true,
            readabilityVersion: nil,
            hasSourceHtml: true
        )
        XCTAssertEqual(ReaderRebuildPolicy.action(for: state), .rerunReadabilityAndRebuild)
    }

    // MARK: - fetchAndRebuildFull: nothing reusable

    func test_noReusableData_fetchesFull() {
        let state = makeState(
            hasCachedHTML: false,
            hasMarkdown: false,
            hasCleanedHtml: false,
            hasSourceHtml: false
        )
        XCTAssertEqual(ReaderRebuildPolicy.action(for: state), .fetchAndRebuildFull)
    }

    func test_cleanedHtmlStale_noSourceHtml_fetchesFull() {
        let state = makeState(
            hasCachedHTML: false,
            hasMarkdown: false,
            hasCleanedHtml: true,
            readabilityVersion: ReaderPipelineVersion.readability - 1,
            hasSourceHtml: false
        )
        XCTAssertEqual(ReaderRebuildPolicy.action(for: state), .fetchAndRebuildFull)
    }

    // MARK: - Isolation invariants

    func test_renderVersionBump_doesNotForceMarkdownRebuild() {
        // When render version is stale but Markdown is current, we only re-render;
        // we do not touch Markdown or Readability.
        let state = makeState(
            hasCachedHTML: true,
            cachedHTMLVersion: ReaderPipelineVersion.readerRender - 1,
            hasMarkdown: true,
            markdownVersion: ReaderPipelineVersion.markdown,
            hasCleanedHtml: true,
            readabilityVersion: ReaderPipelineVersion.readability,
            hasSourceHtml: true
        )
        let action = ReaderRebuildPolicy.action(for: state)
        XCTAssertEqual(action, .rerenderFromMarkdown,
                       "A render-only version bump must not force Markdown or Readability rebuild")
    }

    func test_renderCurrentButReadabilityStale_rerunsReadability() {
        // Current downstream versions are not reusable when Readability is stale.
        let state = makeState(
            hasCachedHTML: true,
            cachedHTMLVersion: ReaderPipelineVersion.readerRender,
            hasMarkdown: true,
            markdownVersion: ReaderPipelineVersion.markdown,
            hasCleanedHtml: true,
            readabilityVersion: ReaderPipelineVersion.readability - 1,
            hasSourceHtml: true
        )
        let action = ReaderRebuildPolicy.action(for: state)
        XCTAssertEqual(action, .rerunReadabilityAndRebuild,
                       "A stale Readability layer must invalidate Markdown and render cache reuse")
    }

    func test_renderCurrentButReadabilityStaleWithoutSource_fetchesFull() {
        let state = makeState(
            hasCachedHTML: true,
            cachedHTMLVersion: ReaderPipelineVersion.readerRender,
            hasMarkdown: true,
            markdownVersion: ReaderPipelineVersion.markdown,
            hasCleanedHtml: true,
            readabilityVersion: ReaderPipelineVersion.readability - 1,
            hasSourceHtml: false
        )
        let action = ReaderRebuildPolicy.action(for: state)
        XCTAssertEqual(action, .fetchAndRebuildFull,
                       "A stale Readability layer with no source HTML must force a full fetch")
    }

    func test_markdownVersionBump_doesNotForceNetworkFetch() {
        // When Markdown is stale but cleaned HTML is current, we rebuild Markdown from
        // cleaned HTML without going back to source HTML or the network.
        let state = makeState(
            hasCachedHTML: true,
            cachedHTMLVersion: ReaderPipelineVersion.readerRender,
            hasMarkdown: true,
            markdownVersion: ReaderPipelineVersion.markdown - 1,
            hasCleanedHtml: true,
            readabilityVersion: ReaderPipelineVersion.readability,
            hasSourceHtml: true
        )
        let action = ReaderRebuildPolicy.action(for: state)
        XCTAssertEqual(action, .rebuildMarkdownAndRender,
                       "A Markdown version bump must use cleaned HTML; it must not trigger a network fetch")
    }

    func test_readabilityVersionBump_withSourceHtml_doesNotForceNetworkFetch() {
        // When Readability version is stale but source HTML is present, we re-run
        // Readability locally without fetching from the network.
        let state = makeState(
            hasCachedHTML: false,
            hasMarkdown: false,
            hasCleanedHtml: true,
            readabilityVersion: ReaderPipelineVersion.readability - 1,
            hasSourceHtml: true
        )
        let action = ReaderRebuildPolicy.action(for: state)
        XCTAssertEqual(action, .rerunReadabilityAndRebuild,
                       "A Readability version bump must reuse source HTML; it must not trigger a network fetch")
    }

    // MARK: - nil version == version 0 contract

    func test_nilVersionTreatedAsVersionZero_renderCache() {
        // nil stored version must behave identically to an explicit stored value of 0.
        let nilState = makeState(hasCachedHTML: true, cachedHTMLVersion: nil, hasMarkdown: false, hasCleanedHtml: false, hasSourceHtml: false)
        let zeroState = makeState(hasCachedHTML: true, cachedHTMLVersion: 0, hasMarkdown: false, hasCleanedHtml: false, hasSourceHtml: false)
        XCTAssertEqual(
            ReaderRebuildPolicy.action(for: nilState),
            ReaderRebuildPolicy.action(for: zeroState),
            "nil cachedHTMLVersion must behave like version 0"
        )
    }

    func test_nilVersionTreatedAsVersionZero_markdown() {
        let nilState = makeState(hasCachedHTML: false, hasMarkdown: true, markdownVersion: nil, hasCleanedHtml: false, hasSourceHtml: false)
        let zeroState = makeState(hasCachedHTML: false, hasMarkdown: true, markdownVersion: 0, hasCleanedHtml: false, hasSourceHtml: false)
        XCTAssertEqual(
            ReaderRebuildPolicy.action(for: nilState),
            ReaderRebuildPolicy.action(for: zeroState),
            "nil markdownVersion must behave like version 0"
        )
    }

    func test_nilVersionTreatedAsVersionZero_readability() {
        let nilState = makeState(hasCachedHTML: false, hasMarkdown: false, hasCleanedHtml: true, readabilityVersion: nil, hasSourceHtml: false)
        let zeroState = makeState(hasCachedHTML: false, hasMarkdown: false, hasCleanedHtml: true, readabilityVersion: 0, hasSourceHtml: false)
        XCTAssertEqual(
            ReaderRebuildPolicy.action(for: nilState),
            ReaderRebuildPolicy.action(for: zeroState),
            "nil readabilityVersion must behave like version 0"
        )
    }
}

// MARK: - Helpers

private extension ReaderPipelineVersioningTests {
    func makeState(
        hasCachedHTML: Bool = false,
        cachedHTMLVersion: Int? = nil,
        hasMarkdown: Bool = false,
        markdownVersion: Int? = nil,
        hasCleanedHtml: Bool = false,
        readabilityVersion: Int? = nil,
        hasSourceHtml: Bool = false
    ) -> ReaderLayerState {
        ReaderLayerState(
            readabilityVersion: readabilityVersion,
            markdownVersion: markdownVersion,
            cachedHTMLVersion: cachedHTMLVersion,
            hasCleanedHtml: hasCleanedHtml,
            hasMarkdown: hasMarkdown,
            hasSourceHtml: hasSourceHtml,
            hasCachedHTML: hasCachedHTML
        )
    }
}
