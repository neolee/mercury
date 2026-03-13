//
//  ReaderRebuildPolicy.swift
//  Mercury
//

/// Snapshot of the persisted layer state for a single content record.
///
/// Each version field follows the convention: nil is treated as version 0,
/// which always mismatches the current version constant >= 1.
nonisolated struct ReaderLayerState: Sendable {
    /// Stored `readabilityVersion` from the `content` row. Nil means version 0.
    var readabilityVersion: Int?
    /// Stored `markdownVersion` from the `content` row. Nil means version 0.
    var markdownVersion: Int?
    /// Stored `readerRenderVersion` from the `content_html_cache` row. Nil means version 0.
    var cachedHTMLVersion: Int?
    /// Whether a non-empty cleaned Readability HTML payload is present.
    var hasCleanedHtml: Bool
    /// Whether a non-empty canonical Markdown payload is present.
    var hasMarkdown: Bool
    /// Whether a non-empty source HTML payload is present (enables re-running
    /// Readability without a network fetch).
    var hasSourceHtml: Bool
    /// Whether a rendered reader HTML cache record exists for the current entry
    /// and theme identity.
    var hasCachedHTML: Bool
}

/// The rebuild action the reader build use case should take for a given layer state.
///
/// Cases are ordered from cheapest to most expensive.
nonisolated enum ReaderRebuildAction: Equatable, Sendable {
    /// The cached rendered HTML is current. Serve it directly.
    case serveCachedHTML
    /// Markdown is current. Re-render from Markdown and refresh the render cache.
    case rerenderFromMarkdown
    /// Cleaned Readability HTML is current. Rebuild Markdown, then re-render.
    case rebuildMarkdownAndRender
    /// Source HTML is present. Re-run Readability, rebuild Markdown, then re-render.
    case rerunReadabilityAndRebuild
    /// No reusable data. Fetch source HTML and run the full pipeline.
    case fetchAndRebuildFull
}

/// Pure decision logic that maps a `ReaderLayerState` to the cheapest valid
/// `ReaderRebuildAction`.
///
/// This function is referentially transparent and has no side effects; it is
/// safe to call from any context without access to a database or network.
nonisolated enum ReaderRebuildPolicy {
    static func action(for state: ReaderLayerState) -> ReaderRebuildAction {
        // Step 1: check cached rendered HTML.
        if state.hasCachedHTML,
           (state.cachedHTMLVersion ?? 0) == ReaderPipelineVersion.readerRender {
            return .serveCachedHTML
        }

        // Step 2: check canonical Markdown.
        if state.hasMarkdown,
           (state.markdownVersion ?? 0) == ReaderPipelineVersion.markdown {
            return .rerenderFromMarkdown
        }

        // Step 3: check cleaned Readability HTML.
        if state.hasCleanedHtml,
           (state.readabilityVersion ?? 0) == ReaderPipelineVersion.readability {
            return .rebuildMarkdownAndRender
        }

        // Step 4: check source HTML (avoids a network fetch).
        if state.hasSourceHtml {
            return .rerunReadabilityAndRebuild
        }

        // Step 5: nothing reusable; must fetch from network.
        return .fetchAndRebuildFull
    }
}
