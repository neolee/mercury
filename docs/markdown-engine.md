# Markdown Rendering Engine

## Background

Mercury uses Markdown as the canonical persisted form of reader content. The pipeline is:

```
Source HTML → Readability → MarkdownConverter → persisted Markdown → ReaderHTMLRenderer → displayed HTML
```

The renderer (`ReaderHTMLRenderer`) currently wraps `Down`, which bundles `libcmark` (CommonMark 0.29.0). This was the original library choice, but it has a structural limitation that requires a planned replacement.

## Current Limitation: No GFM Extension Support

`Down` bundles standard `cmark` (CommonMark spec only). It does **not** include `cmark-gfm` and has no GFM extension support. Concretely:

- GFM pipe table syntax (`| A | B |`) is not parsed as a table node — cmark treats it as paragraph text.
- `~~strikethrough~~` is not recognized.
- Task list checkboxes are not recognized.
- Autolinks are not recognized.

This means that even though `MarkdownConverter` correctly emits GFM table syntax from HTML `<table>` elements (Phase 4), the downstream renderer silently degrades those tables back to paragraph text. The Markdown is structurally correct; the renderer cannot use it.

### Known workarounds currently in the codebase

`MercuryTest/MarkdownConverterFallbackTests.swift` — `test_translationCompatibility_gfmTable_renderedAsTextWithCurrentRenderer`:

```swift
// GFM pipe table syntax is generated correctly, but the current renderer
// (Down/libcmark, no GFM table extension) renders it as paragraph text.
// The surrounding paragraphs remain stable as translation segments.
// Before paragraph (1) + GFM table as paragraph text (1) + after paragraph (1) = 3.
XCTAssertEqual(snapshot.segments.count, 3, ...)
```

This assertion deliberately encodes the degraded behavior. It must be updated when the renderer is replaced.

## Planned Replacement: swift-markdown + Custom HTML Visitor

### Why swift-markdown

[swiftlang/swift-markdown](https://github.com/swiftlang/swift-markdown) is Apple's official Swift Markdown library. It wraps `cmark-gfm` and exposes a typed Swift AST via `MarkupVisitor`. It supports:

- GFM tables (`Table`, `TableHead`, `TableBody`, `TableRow`, `TableCell`)
- GFM strikethrough (`Strikethrough`)
- GFM task list items
- GFM autolinks
- Unsafe inline HTML passthrough (`HTMLBlock`, `InlineHTML`)

It is a **parsing library only** — there is no built-in HTML renderer. A custom `MarkupVisitor` implementation is required to produce HTML output.

### Migration path

1. **Add dependency** — Add `swift-markdown` via Xcode's SPM UI. Do not remove `Down` yet.
2. **Implement renderer** — Create `Mercury/Mercury/Reader/MarkupHTMLVisitor.swift` implementing `MarkupVisitor` with `String` result type. Required node types:
   - Block: `Document`, `Paragraph`, `Heading`, `BlockQuote`, `CodeBlock`, `ThematicBreak`, `UnorderedList`, `OrderedList`, `ListItem`, `HTMLBlock`, `Table`, `TableHead`, `TableBody`, `TableRow`, `TableCell`
   - Inline: `Text`, `SoftBreak`, `LineBreak`, `InlineCode`, `Strong`, `Emphasis`, `Strikethrough`, `Link`, `Image`, `InlineHTML`, `SymbolLink`
3. **Replace renderer call** — Replace the three lines in `ReaderHTMLRenderer.render(markdown:theme:)` that call `Down(markdownString:).toHTML(.unsafe)` with the new visitor.
4. **Bump version** — Increment `ReaderPipelineVersion.readerRenderVersion`. All cached rendered HTML will be lazily rebuilt on next article open per the Phase 0/1 rebuild policy — no startup-blocking migration required.
5. **Update tests** — Fix the GFM table translation compatibility test and add table render verification.
6. **Remove Down** — Manually remove the Down SPM reference from `project.pbxproj` and verify the build.

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

This is the most significant cross-feature side effect of the renderer replacement. Understand it fully before starting.

### How TranslationSegmentExtractor couples to the renderer

`TranslationSegmentExtractor.extract(entryId:markdown:)` does not parse Markdown directly. It:

1. Calls `ReaderHTMLRenderer.render(markdown:themeId:)` — the same Down-backed renderer.
2. Parses the resulting HTML with SwiftSoup, collecting `p`, `ul`, `ol` elements.
3. Computes `sourceSegmentId` for each segment from `element.outerHtml()`.
4. Computes `sourceContentHash` as SHA-256 over all segment payloads.

Translation result rows are keyed by `(entryId, targetLanguage, sourceContentHash, segmenterVersion)`. If `sourceContentHash` changes, the stored translation is no longer found for that entry and appears as "not yet translated".

### What changes after renderer replacement

| Content type | Down output | cmark-gfm output | Hash impact |
|---|---|---|---|
| `p`, `h1–h6`, `code`, `img`, `blockquote`, `a` | Same HTML | Same HTML | No change — translations preserved |
| GFM pipe table (`\| A \| B \|`) | Paragraph text | `<table>` element | Hash changes; stored translations invalidated |
| `~~text~~` (strikethrough) | Literal `~~text~~` text inside `<p>` | `<del>text</del>` inside `<p>` | Hash changes; stored translations invalidated |

**Practical outcome**: Translations for articles that contain tables or strikethrough will be silently invalidated — the UI shows them as untranslated. Users must re-run translation for those articles. There is no data corruption; the old rows remain orphaned and are eventually pruned by the stale-run cleanup policy.

### segmenterVersion does not need to be bumped

`TranslationSegmentationContract.segmenterVersion` is `"v1"` and tracks the segmentation algorithm, not the renderer. The algorithm is unchanged. Only `ReaderPipelineVersion.readerRender` is bumped. The `sourceContentHash` change is the natural invalidation mechanism.

### Pre-migration baseline test required

Before writing the visitor, add a test that captures `sourceContentHash` for a plain Markdown document (paragraphs, headings, code blocks, images — no tables or strikethrough). After replacing Down with the visitor, this test must still pass, confirming that the majority of existing translations survive the migration.

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

### Acceptance criteria

- All existing `MarkdownConverter*Tests` pass without modification (converter is unchanged).
- `test_translationCompatibility_gfmTable_renderedAsTextWithCurrentRenderer` is renamed and its assertion is updated to expect `2` segments (table now renders as a real `<table>` element, which is not a collected segment type).
- New test: GFM table round-trip — `<table>` HTML → Markdown → rendered HTML contains a `<table>` element.
- New test: Strikethrough round-trip — `<del>text</del>` → `~~text~~` Markdown → rendered HTML contains a `<del>` element.
- New test: Translation hash stability — for a plain Markdown document (no GFM extensions), `sourceContentHash` is identical between the old renderer and the new visitor.
- `ReaderPipelineVersion.readerRender` is bumped.
- New CSS rules for `table`, `del`, and optionally `hr` are present in `ReaderHTMLRenderer.css(for:)`.
- No `import Down` anywhere in the codebase.
- `./scripts/build` succeeds with zero warnings.

## Status

| Step | Status |
|---|---|
| Phase 0–5: MarkdownConverter (HTML → Markdown) | Complete |
| Add swift-markdown SPM dependency | Not started — manual Xcode UI action by owner |
| Implement `MarkupHTMLVisitor` | Not started |
| Add CSS rules for `table`, `del`, `hr` | Not started |
| Replace Down in `ReaderHTMLRenderer` | Not started |
| Add pre-migration translation hash stability test | Not started |
| Add GFM table and strikethrough round-trip tests | Not started |
| Remove Down dependency | Not started — manual `project.pbxproj` edit by owner |
