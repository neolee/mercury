# Markdown Rendering Engine

## Background

Mercury uses Markdown as the canonical persisted form of reader content. The pipeline is:

```
Source HTML → Readability → MarkdownConverter → persisted Markdown → ReaderHTMLRenderer → displayed HTML
```

The renderer is now implemented as `swift-markdown` parsing plus Mercury's internal `MarkupHTMLVisitor`. This document records both the migration rationale and the resulting runtime contract.

## Current State

Current implementation:

- `ReaderHTMLRenderer` parses Markdown with `swift-markdown`
- `MarkupHTMLVisitor` renders the Markdown AST to Reader HTML
- `ReaderPipelineVersion.readerRender` is set to `1` as the new post-migration baseline
- `content_html_cache` is lazily rebuilt when `readerRenderVersion` mismatches
- translation persistence remains untouched on Reader open and is evaluated only on explicit translation invocation

Practical results of the migration:

- GFM pipe tables render as real `<table>` elements
- `~~strikethrough~~` renders as `<del>`
- raw inline / block HTML passthrough needed by Mercury's canonical Markdown contract is preserved
- historical `Down` / `libcmark` dependency has been removed from the app

## Historical Limitation: No GFM Extension Support

Before this migration, Mercury used `Down`, which bundled standard `cmark` (CommonMark spec only). It did **not** include `cmark-gfm` and had no GFM extension support. Concretely:

- GFM pipe table syntax (`| A | B |`) is not parsed as a table node — cmark treats it as paragraph text.
- `~~strikethrough~~` is not recognized.
- Task list checkboxes are not recognized.
- Autolinks are not recognized.

This means that even though `MarkdownConverter` correctly emits GFM table syntax from HTML `<table>` elements (Phase 4), the downstream renderer silently degrades those tables back to paragraph text. The Markdown is structurally correct; the renderer cannot use it.

### Historical workaround encoded in tests

The old degraded behavior was previously encoded in `MercuryTest/MarkdownConverterFallbackTests.swift`:

```swift
// Before the renderer migration, the GFM table degraded into paragraph text.
// After the migration, the table renders as <table> and is excluded from
// the collected translation segment types.
XCTAssertEqual(snapshot.segments.count, 2, ...)
```

That test has now been updated to assert the new behavior.

## Implemented Replacement: swift-markdown + Custom HTML Visitor

### Why swift-markdown

[swiftlang/swift-markdown](https://github.com/swiftlang/swift-markdown) is Apple's official Swift Markdown library. It wraps `cmark-gfm` and exposes a typed Swift AST via `MarkupVisitor`. It supports:

- GFM tables (`Table`, `TableHead`, `TableBody`, `TableRow`, `TableCell`)
- GFM strikethrough (`Strikethrough`)
- GFM task list items
- GFM autolinks
- Unsafe inline HTML passthrough (`HTMLBlock`, `InlineHTML`)

It is a **parsing library only** — there is no built-in HTML renderer. A custom `MarkupVisitor` implementation is required to produce HTML output.

### Implemented migration steps

1. `swift-markdown` target integration is wired for the app target.
2. `Mercury/Mercury/Reader/MarkupHTMLVisitor.swift` implements `MarkupVisitor` with `String` result type and covers the required block and inline nodes:
   - Block: `Document`, `Paragraph`, `Heading`, `BlockQuote`, `CodeBlock`, `ThematicBreak`, `UnorderedList`, `OrderedList`, `ListItem`, `HTMLBlock`, `Table`, `TableHead`, `TableBody`, `TableRow`, `TableCell`
   - Inline: `Text`, `SoftBreak`, `LineBreak`, `InlineCode`, `Strong`, `Emphasis`, `Strikethrough`, `Link`, `Image`, `InlineHTML`, `SymbolLink`
3. `ReaderHTMLRenderer.render(markdown:theme:)` now renders through the visitor rather than `Down`.
4. `ReaderPipelineVersion.readerRender` is bumped, so cached rendered HTML is lazily rebuilt on next article open.
5. Translation compatibility handling is exact-hash based. When the user explicitly invokes translation behavior, Mercury compares the persisted translation record's `sourceContentHash` with the current snapshot:
   - exact match: keep the existing partial-coverage / retry behavior
   - mismatch: delete the stale persisted translation record for that `(entryId, targetLanguage)` slot and treat the entry as untranslated
6. The relevant GFM table, strikethrough, translation hash, and translation compatibility tests have been updated or added.
7. `Down` has been removed from the project.

### CSS compatibility and new rules required

The custom visitor must produce HTML that the existing CSS rules in `ReaderHTMLRenderer.css(for:)` can target. The article root is `article.reader`; all content sits inside it.

The current CSS covers: `body`, `.reader`, `p`, `h1–h6`, `img`, `blockquote`, `a`, `code`, `pre`.

**New CSS rules that must be added alongside the visitor:**

| Element | Trigger |
|---|---|
| `table`, `thead`, `tbody`, `tr`, `th`, `td` | GFM pipe tables now render as real `<table>` |
| `del` | `~~strikethrough~~` now renders as `<del>` instead of literal `~~text~~` |
| `hr` | ThematicBreak produces `<hr>` — browser default may suffice; verify against theme colors |

Add these rules to `ReaderHTMLRenderer.css(for:)` in the same change that introduces the visitor.

---

## Translation System Impact

This was the most significant cross-feature side effect of the renderer replacement and remains the key compatibility rule after migration.

### How TranslationSegmentExtractor couples to the renderer

`TranslationSegmentExtractor.extract(entryId:markdown:)` does not parse Markdown directly. It:

1. Calls `ReaderHTMLRenderer.render(markdown:themeId:)` — the same Reader renderer used by the app.
2. Parses the resulting HTML with SwiftSoup, collecting `p`, `ul`, `ol` elements.
3. Computes `sourceSegmentId` for each segment from `element.outerHtml()`.
4. Computes `sourceContentHash` as SHA-256 over all segment payloads.

Translation result rows are keyed by `(entryId, targetLanguage, sourceContentHash, segmenterVersion)`. If `sourceContentHash` changes, the stored translation is no longer found for that entry and appears as "not yet translated".

### What changes after renderer replacement

| Content type | Old output | New output | Hash impact |
|---|---|---|---|
| `p`, `h1–h6`, `code`, `img`, `blockquote`, `a` | Same HTML | Same HTML | No change — translations preserved |
| GFM pipe table (`\| A \| B \|`) | Paragraph text | `<table>` element | Hash changes; stored translations invalidated |
| `~~text~~` (strikethrough) | Literal `~~text~~` text inside `<p>` | `<del>text</del>` inside `<p>` | Hash changes; stored translations invalidated |

**Practical outcome**: Translations for articles whose collected `p` / `ul` / `ol` snapshot changes will no longer match the current `sourceContentHash`. Those articles must be translated again. Under the migration policy below, stale translation rows are not auto-migrated or cross-hash salvaged; they are deleted when the user explicitly invokes translation for the current slot and the hash check fails.

### segmenterVersion does not need to be bumped

`TranslationSegmentationContract.segmenterVersion` is `"v1"` and tracks the segmentation algorithm, not the renderer. The algorithm is unchanged. Only `ReaderPipelineVersion.readerRender` is bumped. The `sourceContentHash` change is the natural invalidation mechanism.

### Baseline compatibility test

A plain-Markdown baseline test captures `sourceContentHash` for a document with paragraphs, headings, code blocks, and images but no GFM-only features. That test continues to pass after the renderer migration and serves as the guardrail for non-GFM compatibility.

### Translation compatibility policy for this migration

The translation behavior for this renderer replacement is intentionally strict. The goal is clarity and correctness, not best-effort cross-version salvage.

Rules:

1. Opening a Reader entry may rebuild `content_html_cache`, but it must not migrate, delete, or rewrite translation persistence.
2. Translation persistence is evaluated only when the user explicitly invokes translation-related behavior.
3. The compatibility check is exact:
   - same `sourceContentHash` + same `segmenterVersion` means "same source snapshot"
   - any `sourceContentHash` mismatch means "different source snapshot"
4. If the hash matches, keep the existing behavior:
   - reuse already translated segments
   - show missing segments as untranslated
   - allow per-segment retry or "complete missing translation" flows
5. If the hash does not match:
   - do not attempt cross-hash segment salvage
   - delete the stale translation persistence for the current `(entryId, targetLanguage)` slot
   - treat the entry as having no translation data and require a full fresh translation

This policy is intentionally different from the same-snapshot partial-failure retry behavior. Partial retry exists to finish an incomplete translation run for unchanged content. It must not be generalized to content-version drift caused by renderer replacement.

### Why this policy is preferred

- It keeps the runtime behavior easy to reason about.
- It avoids mixing old translations with a new Reader HTML snapshot.
- It makes correctness dependent on one exact condition (`sourceContentHash` match) instead of heuristic compatibility rules.
- It keeps the migration testable: either a document still hashes the same and remains valid, or it is treated as untranslated and rebuilt from scratch.

---

## MarkupHTMLVisitor Design Scope

The user-facing question: should `MarkupHTMLVisitor` be designed as a reusable, general-purpose module?

**Answer: No — keep it internal to the Reader group.**

Rationale:

- The visitor's only current consumer is `ReaderHTMLRenderer`. The Summary agent uses plain Markdown text for LLM prompts, not rendered HTML. There is no second rendering path in the app.
- The visitor is tightly coupled to the CSS contract it targets. A "general-purpose" visitor would require configurable output shapes, which adds complexity with no current payoff.
- The visitor's correctness is defined relative to the CSS rules in `ReaderHTMLRenderer` — keeping both in the same file group (`Mercury/Mercury/Reader/`) makes this relationship explicit and co-evolvable.

**Do design the API cleanly:**

- File: `Mercury/Mercury/Reader/MarkupHTMLVisitor.swift`
- Implement `MarkupVisitor` with `Result = String`
- Top-level entry point: `MarkupHTMLVisitor().visit(document)` where `document: Markdown.Document`
- The visitor should be `struct` or `class` with no stored state between visits, so it can be instantiated per render call
- Unit-test it directly (parse a Markdown string into `Document`, invoke the visitor, assert HTML) — no need for full `ReaderHTMLRenderer` integration in low-level tests

If a second Markdown → HTML use case arises in the future (e.g., clipboard export, email-style share sheet), promote to a shared utility at that point.

### On extracting MarkupHTMLVisitor as a public library

`swift-markdown` ships no HTML renderer — the gap is real and the Swift ecosystem has no well-maintained option. In principle, a public `swift-markup-html` library is feasible.

However, a Mercury-internal visitor and a genuinely useful public library are different artifacts. The internal visitor is output-shaped for one CSS contract, covers only the node types an RSS reader encounters, and needs no configuration surface. A public library would require complete node coverage (including `SymbolLink`, task list checkboxes), a configurable class/element mapping API, explicit unsafe-HTML passthrough policy, and documentation to public-library standards. That is substantially more work with no benefit to Mercury itself.

Compare with `swift-readability`: the Readability algorithm is fully decoupled from any rendering or theming concern, so any Swift app that needs article extraction benefits directly — that justified the investment. The visitor's output is inherently shaped around a reader-app rendering contract and does not have the same standalone utility.

**Decision**: Implement as a Mercury-internal type. If the visitor is ever promoted to a public library, that is a separate, deliberate project undertaken after Mercury ships — not a scope addition to this migration.

---

### Acceptance criteria status

- All existing `MarkdownConverter*Tests` pass without modification (converter is unchanged).
- `test_translationCompatibility_gfmTable_isExcludedFromCollectedSegments` expects `2` segments because the table now renders as a real `<table>` element and is not a collected segment type.
- New test: GFM table round-trip — `<table>` HTML → Markdown → rendered HTML contains a `<table>` element.
- New test: Strikethrough round-trip — `<del>text</del>` → `~~text~~` Markdown → rendered HTML contains a `<del>` element.
- New test: Translation hash stability — for a plain Markdown document (no GFM extensions), `sourceContentHash` is identical between the old renderer and the new visitor.
- New test: Translation lookup with matching `sourceContentHash` keeps the existing partial-coverage behavior.
- New test: Translation invocation with mismatched `sourceContentHash` deletes stale translation persistence and treats the entry as untranslated.
- `ReaderPipelineVersion.readerRender` is set to `1` as the new baseline.
- New CSS rules for `table`, `del`, and optionally `hr` are present in `ReaderHTMLRenderer.css(for:)`.
- No `import Down` anywhere in the codebase.
- `./scripts/build` succeeds with zero warnings.

## Implementation record

### Phase 1 — Lock the migration contract in tests

1. Add a plain-Markdown translation hash stability test to capture the expected "compatible" baseline.
2. Add translation persistence tests for the two runtime branches:
   - exact hash match keeps current partial-translation behavior
   - hash mismatch deletes stale translation data for the current slot and falls back to empty-state translation behavior
3. Land the minimal exact-hash runtime gate needed to exercise those tests without changing the renderer yet.

### Phase 2 — Implement the new Reader renderer

1. Add `Mercury/Mercury/Reader/MarkupHTMLVisitor.swift`.
2. Cover the required block and inline AST nodes.
3. Preserve raw inline / block HTML passthrough behavior needed by Mercury's canonical Markdown contract.
4. Keep the generated `p` / `ul` / `ol` HTML as compatible as possible with the old renderer when no GFM-only feature is involved.

### Phase 3 — Integrate the renderer and CSS

1. Replace the `Down`-backed body rendering in `ReaderHTMLRenderer`.
2. Add CSS rules for `table`, `thead`, `tbody`, `tr`, `th`, `td`, `del`, and verify `hr`.
3. Bump `ReaderPipelineVersion.readerRender`.
4. Update the existing GFM table translation compatibility test to encode the new behavior.

### Phase 4 — Tighten translation runtime behavior

1. Leave translation persistence untouched when a Reader entry is merely opened.
2. On translation invocation, build the current snapshot from the rebuilt Reader HTML.
3. Compare persisted `sourceContentHash` and `segmenterVersion` with the current snapshot.
4. If they match, continue to use the existing partial-coverage / retry flow.
5. If they do not match, delete the stale translation record for the current slot and proceed as a full fresh translation.

### Phase 5 — Remove legacy renderer code and verify the build

1. Remove all `Down` imports and package references.
2. Run the full Reader / Translation test set.
3. Run `./scripts/build` and confirm zero warnings.

## Status

| Step | Status |
|---|---|
| Phase 0–5: MarkdownConverter (HTML → Markdown) | Complete |
| Add swift-markdown target dependency | Complete |
| Lock translation migration contract in tests | Complete |
| Implement `MarkupHTMLVisitor` | Complete |
| Add CSS rules for `table`, `del`, `hr` | Complete |
| Replace Down in `ReaderHTMLRenderer` | Complete |
| Tighten translation runtime to exact-hash compatibility checks | Complete |
| Add pre-migration translation hash stability test | Complete |
| Add GFM table and strikethrough round-trip tests | Complete |
| Remove Down dependency | Complete |
