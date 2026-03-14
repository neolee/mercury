# Reader Mode Round-Trip Design

## Scope

This document defines the intended round-trip contract for Mercury reader content:

`Readability HTML -> Markdown -> Reader HTML`

The pipeline is intentional and should remain in place. Markdown is the canonical persisted format because it is more useful than HTML for downstream tasks such as:

- LLM input preparation
- export and sharing
- user-side reuse and editing
- future content transformations

The goal is not byte-for-byte HTML equality. The goal is semantic round-trip equivalence:

- article structure remains intact,
- media remains media,
- links remain links,
- captions remain captions,
- translated segment boundaries stay stable,
- the rendered reader output is meaningfully equivalent to the sanitized `Readability` output.

## Current Pipeline

### Current implementation

Today the persisted reader flow is:

1. fetch source HTML
2. run `Readability.parse()`
3. convert `ReadabilityResult.content` into Markdown in `Mercury/Mercury/Reader/Markdown.swift`
4. persist original source HTML to `Content.html`
5. persist generated Markdown to `Content.markdown`
6. render Markdown back to HTML with `swift-markdown` + `MarkupHTMLVisitor` in `Mercury/Mercury/Reader/Reader.swift`
7. persist rendered reader HTML into `content_html_cache`

Important clarification:

- `Content.html` stores fetched source HTML
- `Content.cleanedHtml` stores cleaned `Readability` HTML
- `Content.markdown` stores the canonical persisted Markdown

This means current rebuild behavior is:

- renderer changes can reuse persisted Markdown,
- Markdown-converter changes require rebuilding Markdown from persisted cleaned HTML,
- Markdown rebuild can reuse source HTML to avoid network fetch when `Readability` must rerun,
- `Readability` work can be skipped when `cleanedHtml` is present and its version is still valid.

The main fidelity loss is still dominated by the `Readability HTML -> Markdown` step rather than the final Markdown renderer.

### Target layered pipeline

The intended steady-state architecture should be:

1. fetch and persist source HTML
2. run `Readability.parse()` and persist cleaned `Readability` HTML
3. convert cleaned `Readability` HTML into canonical Markdown and persist it
4. render Markdown into final reader HTML and cache it per effective render identity

This layered design is preferred because it allows Mercury to invalidate only the layer that is affected by a given code change.

## Target Storage Model

Mercury should move to an explicit multi-stage persisted reader representation.

Recommended logical layers:

- source HTML
  - purpose: avoid re-downloading the original page
  - truth source for re-running `Readability`
- cleaned `Readability` HTML
  - purpose: avoid re-running `Readability` when only Markdown conversion changes
  - truth source for `Readability HTML -> Markdown`
- canonical Markdown
  - purpose: durable text-first article representation for reader, LLM, export, and reuse
  - truth source for `Markdown -> Reader HTML`
- rendered reader HTML cache
  - purpose: avoid rerendering on repeated open for the same article and render identity

Recommended data-model direction:

- keep current persisted source HTML
- add a dedicated persisted cleaned-HTML field for `ReadabilityResult.content`
- keep persisted canonical Markdown
- keep rendered HTML cache separate

The important architectural rule is that each stored layer must have one clear upstream source and one clear invalidation policy.

## Storage Trade-Offs

Persisting cleaned `Readability` HTML does increase database size, but the trade-off is favorable for Mercury.

### Expected benefits

- avoids repeating relatively expensive `Readability` extraction when only Markdown conversion changes
- keeps rebuilds local to the cheapest necessary layer
- makes layered testing and targeted invalidation practical

### Expected storage cost

- there is one additional article-body payload for entries that have been built for reader mode
- this payload is typically smaller and cleaner than source HTML because scripts, styles, navigation, and other non-article content are removed
- the increase is meaningful but should remain acceptable for a desktop RSS reader with local storage

### Policy conclusion

Mercury should accept the extra storage cost in exchange for:

- lower rebuild latency,
- reduced network dependence,
- more reliable versioned upgrades,
- clearer pipeline semantics.

This is the right trade-off for a local-first desktop reader.

## Current Regression: Linked Image Collapses Into URL Text

Observed symptom:

```text
https://substackcdn.com/image/fetch/... Many of you may think ...
```

In the reader this appears as a clickable URL string instead of an image.

### Root Cause

The problem is in Mercury's Markdown conversion, not primarily in `Readability`.

The current `<a>` handling in `Mercury/Mercury/Reader/Markdown.swift` does this:

- read `element.text()`
- read `href`
- if link text is empty, emit `[href](href)`

That is incompatible with links that wrap media:

```html
<a href="https://...">
  <img src="https://..." alt="">
</a>
```

For this shape:

- `element.text()` is empty,
- `href` is present,
- the converter emits the URL as visible text,
- the nested image is discarded.

This is why the user-visible output contains the image CDN URL itself.

This also strongly indicates that the issue is not coming from the `result.textContent` fallback, because `textContent` would not normally include an image `src` URL. The visible URL matches the `<a href>` fallback behavior much more closely.

### Why `Readability` Is Not the Primary Problem

The current `Readability` implementation already preserves and normalizes media URLs in its cleaned article tree. It explicitly rewrites media `src` and `srcset` URLs to absolute form before serialization. That behavior is consistent with Mercury receiving structured media HTML and then degrading it during Markdown conversion.

`Readability` may still need small shape-level adjustments over time, but the specific linked-image regression is best explained by Mercury's converter.

## Design Principle: Canonical Markdown, Not Markdown-Only

Mercury should treat persisted Markdown as the canonical source format, but not as a restricted "plain Markdown only" subset.

The right model is:

- prefer native Markdown when it can preserve semantics cleanly,
- allow a single-layer, single-line HTML tag only when Markdown alone cannot preserve the semantics and the tag stays compact enough to be readable inline,
- for anything more complex, fall back to current behavior rather than introducing multi-line or nested HTML into persisted Markdown.

This is practical because:

- `Readability` output is already sanitized and app-authored,
- most article structures can be expressed in clean Markdown with minimal loss,
- some HTML structures have no faithful Markdown equivalent but can be handled with narrow inline tags or acceptable current-behavior fallbacks.

Mercury's Reader renderer now preserves trusted raw inline and block HTML through `swift-markdown` AST nodes (`InlineHTML`, `HTMLBlock`) and `MarkupHTMLVisitor`. `Readability` output is already sanitized, so preserving these narrow HTML fragments in canonical Markdown is appropriate for this pipeline.

This gives Mercury a readable, loss-minimizing canonical format without abandoning Markdown as the stored representation.

### Practical policy for embedded HTML

Markdown remains the preferred representation. Embedded HTML is a last resort, not a default escape hatch.

The intended rule is:

- prefer pure Markdown whenever semantics can be preserved cleanly,
- allow a single-layer, single-line HTML tag only when Markdown cannot preserve the semantics and the tag stays compact and readable inline,
- for anything more complex, fall back to current behavior rather than introducing verbose or multi-level HTML into persisted Markdown.

Concretely: a `<sup>1</sup>` inline tag is acceptable when no Markdown equivalent exists. A `<figure>` block containing `<img>` and `<figcaption>` is not, because it requires multiple lines and nested elements.

This means Mercury should not treat "lossless at any cost" as the goal. The goal is:

- semantically faithful where achievable without HTML noise,
- readable as Markdown,
- deterministic,
- easy to reuse in LLM and export paths.

## Round-Trip Contract

The conversion should preserve the following invariants.

### Block structure

- headings remain headings at the same level
- paragraphs remain paragraphs
- ordered and unordered lists preserve nesting and order
- block quotes remain block quotes
- code blocks remain code blocks

### Inline semantics

- links remain links
- emphasis remains emphasis
- strong emphasis remains strong emphasis
- inline code remains inline code
- hard line breaks remain hard line breaks when semantically meaningful

### Media semantics

- standalone images remain images
- linked images remain linked images
- figures remain figures
- captions remain captions
- picture-based responsive images degrade to a stable chosen image representation, not plain text

### Structural safety

- all URLs stay absolute
- unsupported constructs never silently degrade into misleading plain text
- when lossless Markdown is impossible, preserve trusted raw HTML instead

### Translation compatibility

Translation currently segments rendered output by `p`, `ul`, and `ol`. The round-trip must avoid gratuitous structural rewrites that would:

- merge adjacent paragraphs,
- split a paragraph into multiple unrelated blocks,
- convert textual blocks into non-text blocks unnecessarily,
- destabilize the segment hash for unchanged article content.

## Recommended Conversion Strategy

### 1. Make the converter DOM-aware instead of text-flattening

The current converter often uses `element.text()` for structured nodes. That is too lossy for round-trip fidelity.

The converter should prefer:

- recursive child rendering for inline containers
- explicit block rendering for block containers
- raw HTML passthrough for unsupported or ambiguous structures

In practice this means `<a>` should render its child content, not flatten to plain text first.

### 2. Represent linked images explicitly

For a link whose meaningful child content is a single image, Mercury should emit either:

```md
[![Alt](https://example.com/image.jpg)](https://example.com/target)
```

or trusted raw HTML:

```html
<a href="https://example.com/target"><img src="https://example.com/image.jpg" alt="Alt"></a>
```

Preferred rule:

- use Markdown nested image syntax for the simple `a > img` case,
- use raw HTML passthrough for more complex media containers such as `a > picture`, `a > figure`, or links with mixed media plus caption content.

### 3. Use native Markdown only when it is semantically complete

Recommended mapping:

| Readability HTML | Preferred Markdown form | Notes |
| --- | --- | --- |
| `h1...h6` | ATX headings | Preserve level |
| `p` | paragraph | Preserve inline children recursively |
| `br` | hard break | Preserve only where meaningful |
| `ul` / `ol` | Markdown lists | Preserve nesting and item boundaries |
| `blockquote` | block quote | Preserve nested block structure |
| `pre > code` | fenced code block | Preserve raw code text |
| `code` | code span | Escape backticks correctly |
| `img` | `![](...)` | Preserve alt text and title if present |
| `a` with text-only children | `[]()` | Preserve inline formatting inside the label when possible |
| `a > img` | `[![]()]()` | Do not fall back to URL text |
| `hr` | `---` | Add explicit support |
| `em` / `i` | `*...*` or `_..._` | Preserve inline emphasis |
| `strong` / `b` | `**...**` | Preserve strong emphasis |
| `del` / `s` | `~~...~~` | Preserve strike-through when present |

Recommended raw HTML passthrough cases:

- `figure` when a short wrapper preserves caption grouping clearly
- `figcaption` only together with its `figure`
- `picture` only when reducing to a single `img` would lose important semantics
- `video`
- `audio`
- `iframe` if ever allowed by sanitized output
- tables that are too complex for readable Markdown representation
- any container whose semantics cannot be preserved with the local Markdown subset

### 4. Introduce a "lossless fallback" rule

For each DOM node:

- if Mercury has a known lossless Markdown representation, use it,
- otherwise emit sanitized raw HTML for that subtree,
- never silently collapse a structured subtree into plain text.

This rule is more important than maximizing Markdown purity.

At the same time, fallback HTML should stay intentionally minimal. It should preserve semantic grouping, not mirror the entire original subtree unnecessarily.

## Important Gaps in the Current Converter

The linked-image bug is only one symptom. The current converter has several other fidelity risks that should be addressed.

### A. `<a>` currently drops nested inline semantics

Current behavior flattens link content with `element.text()`.

This loses:

- inline code inside links
- emphasis inside links
- images inside links
- any future structured inline content

Recommended fix:

- render child nodes recursively,
- only fall back to plain text when the rendered child content is genuinely empty.

### B. Inline formatting is mostly unsupported

The current converter has no explicit handling for:

- `em`
- `strong`
- `b`
- `i`
- `del`
- `s`
- `sup`
- `sub`

Most of these currently degrade to plain text via the default child-rendering path, which loses semantics.

Recommended fix:

- support native Markdown where available,
- otherwise preserve inline raw HTML for tags such as `sup` and `sub`.

### C. `figure` and `figcaption` semantics are not preserved

Figures are common in cleaned article output. Markdown has no native figure model.

If Mercury converts `figure` by only rendering children, it can:

- detach captions from media,
- flatten attribution text into unrelated paragraphs,
- break image-credit presentation,
- lose semantic grouping needed for future exports.

Recommended fix:

- for simple `figure > img + figcaption`, prefer a compact HTML wrapper that stays easy to read in Markdown,
- for example, preserve a short `<figure>...</figure>` block rather than flattening caption text into unrelated paragraphs,
- avoid verbose preservation of irrelevant attributes,
- if a figure can be reduced to plain Markdown image plus nearby caption without semantic ambiguity, that is also acceptable, but the mapping must be deterministic.

### D. `picture` and responsive-image structure need an explicit policy

`Readability` may preserve `picture`, `source`, and `srcset`-based structures. Markdown cannot represent those directly.

Recommended policy:

- for common responsive-image wrappers where all sources represent the same image, choose a deterministic primary `img/src` and emit a normal Markdown image,
- preserve only a compact HTML form when reducing to `img` would drop meaningful semantics such as art direction or unavailable primary `src`,
- never preserve `picture` markup just because it exists if a clean Markdown image is equivalent in practice.

This policy should be deterministic so the same cleaned HTML always produces the same Markdown.

### E. Tables are currently unsafe to flatten

The current converter does not explicitly support tables.

Blind flattening would:

- destroy row and column relationships,
- produce misleading text order,
- break later exports.

Recommended fix:

- define a strict "simple table" subset that Mercury may convert into GFM table syntax,
- keep complex tables as HTML only if the resulting HTML stays acceptably readable,
- if the HTML would be too noisy for Markdown usability, prefer a simplified textual equivalent rather than dumping a large raw table subtree.

Suggested simple-table subset:

- one header row or no header row,
- no merged cells,
- no nested block content inside cells,
- no media-heavy cells,
- no multi-paragraph cell layout.

Suggested fallback policy for non-simple tables:

- preserve a minimal HTML table only when the structure is still compact,
- otherwise emit a readable textual summary form such as row-wise bullet groups,
- record that this is an intentional "near-equivalent" fallback rather than a fully lossless one.

### F. Nested lists need explicit indentation handling

The current list logic is shallow and does not model nested list indentation precisely.

Recommended fix:

- track list depth and indentation explicitly,
- preserve nested list structure instead of relying on naive recursive text concatenation.

### G. Markdown escaping is currently incomplete

Text, alt text, captions, and inline code can contain Markdown metacharacters. Without proper escaping, rendered output may gain accidental formatting or malformed syntax.

Recommended fix:

- add dedicated escaping helpers for plain text, link labels, alt text, and code spans,
- avoid reusing one generic escape rule for all contexts.

### H. Heading rendering currently flattens inline markup

Headings currently use `element.text()`, which strips inline emphasis and code within headings.

Recommended fix:

- render heading children recursively using inline rules,
- then wrap the result with the heading marker.

### I. Paragraphs containing block-like media need a stable rule

A paragraph may contain only media, or media followed by text, or a linked image followed by prose.

Recommended fix:

- keep pure media paragraphs as a media block followed by paragraph separation,
- preserve mixed inline media within paragraph flow when the structure is truly inline,
- avoid injecting extra blank lines that change layout or translation segmentation.

### J. `textContent` fallback should remain rare and observable

Falling back to `result.textContent` is acceptable only when structured conversion fails completely.

It should not be used as a normal path because it discards:

- media
- links
- captions
- block semantics
- inline formatting

Recommended fix:

- keep the fallback,
- but record a debug signal or versioned metric when it is used,
- treat high fallback frequency as a converter regression indicator.

## Recommended Canonicalization Rules

To keep the Markdown deterministic and stable across versions, the converter should follow canonical output rules.

### Canonical whitespace

- collapse meaningless whitespace
- preserve meaningful line breaks
- normalize repeated blank lines between block nodes
- avoid accidental leading or trailing spaces around inline wrappers

### Canonical URLs

- assume `Readability` already normalized URLs to absolute form
- preserve those URLs as-is
- do not re-resolve relative URLs during Markdown generation

### Canonical raw HTML usage

- only emit inline HTML for tags in the approved single-layer single-line set
- the approved set: `sup`, `sub`, and other single-line inline-only tags with no Markdown equivalent that have been explicitly verified to improve output
- do not emit block-level or nested HTML; use Markdown or current-behavior fallback for those structures
- do not mix partially converted Markdown with partially broken HTML for the same node
- strip all attributes not required for meaning
- if equivalent readable Markdown exists, always prefer Markdown over HTML

### Canonical stability

- same input HTML should always produce the same Markdown
- semantically irrelevant attribute ordering should not change output
- equivalent media structures should map deterministically

## Implementation Plan

### Phase 0: Define layered persistence contract and architecture tests

This phase establishes the long-term storage and invalidation model before converter behavior changes.

Required outputs:

- finalized persisted-layer contract
  - source HTML
  - cleaned `Readability` HTML
  - canonical Markdown
  - rendered reader HTML cache
- finalized version contract
  - `readabilityVersion`
  - `markdownVersion`
  - `readerRenderVersion`
- rebuild decision contract
- first architecture-level tests for rebuild and invalidation behavior

Required tests:

- layer reuse contract tests
- version mismatch contract tests
- tests proving renderer invalidation does not force Markdown rebuild
- tests proving Markdown invalidation does not force source re-download when reusable upstream data exists

This phase should happen first because the rest of the implementation depends on stable persistence and invalidation boundaries.

### Phase 1: Land schema migration and lazy-upgrade rebuild orchestration

This phase implements the database and runtime behavior implied by Phase 0.

Required work:

- add schema support for cleaned `Readability` HTML, `Readability`-extracted title and byline, and explicit version metadata
- keep migration backward-compatible and lazy-upgrade friendly
- update reader build orchestration to follow ordered version checks
- ensure source HTML can be reused without network fetch during downstream rebuilds
- store `readerRenderVersion` alongside rendered cache records for post-lookup validity checking
- ensure the Reader renderer preserves trusted raw inline / block HTML passthrough required by the canonical Markdown contract
- add instrumentation or debug events that reveal which layer was reused or rebuilt

Required tests:

- migration tests
- lazy-upgrade tests for pre-existing rows
- rebuild-order integration tests
- tests proving old rows upgrade without startup-time blocking work

Required verification:

- opening an untouched old article upgrades it without user intervention
- Markdown-version bumps do not trigger network fetch when source HTML already exists
- renderer-version bumps invalidate only rendered cache
- `Readability` version bumps rebuild cleaned HTML and downstream layers

### Phase 2: Fix the linked-image regression

Minimum change set:

- change `<a>` rendering to recurse into children
- support linked images without visible URL fallback
- add tests for `a > img`
- add tests for `a > picture > img`

This closes the concrete user-visible bug.

### Phase 3: Add missing inline semantics and escaping

Required work:

- support `em`, `strong`, `del`, `sup`, `sub`
- render headings with inline children instead of flattened text
- add Markdown escaping helpers

Required tests:

- inline formatting canonicalization tests
- heading inline-format tests
- escaping tests for Markdown metacharacters

This improves general round-trip fidelity for typical long-form prose.

### Phase 4: Add fallback handling for unsupported structures

This phase follows the strict inline HTML policy from the design principles: prefer pure Markdown, allow only single-layer single-line HTML tags when strictly necessary, and fall back to current behavior for anything more complex.

The current Reader renderer already preserves single-layer single-line inline HTML that survives parsing as `InlineHTML` or `HTMLBlock`, so these fragments can survive through to the final output.

Priority order for unsupported structures:

1. convert to clean native Markdown when semantics remain intact
2. use a single-layer single-line HTML tag only when Markdown cannot represent the semantics and the tag fits inline without block nesting
3. for anything else, fall back to current behavior rather than introducing multi-line or nested HTML into persisted Markdown

Recommended structure-by-structure policy:

- `figure`
  - simple image figure with caption: Markdown image followed by caption as a plain paragraph or emphasis line; do not preserve the `<figure>` wrapper as HTML
  - figure with complex nested media: fall back to current behavior
- `figcaption`
  - render caption text as a plain paragraph or emphasis line; do not preserve the tag wrapper
- `picture`
  - collapse to Markdown image when all sources are semantically equivalent
  - fall back to a plain Markdown image from the best available source if no clear primary exists
- `table`
  - attempt GFM table conversion for all tables; fall back to current behavior only when GFM conversion is not possible
  - do not pre-classify tables as simple or complex; handle edge cases as they arise
- `video` and `audio`
  - emit a compact single-line fallback link if a usable URL is available
  - fall back to current behavior if no usable URL is present
- inline-only tags such as `sup` and `sub`
  - acceptable as single-layer single-line inline HTML when no Markdown equivalent exists

Acceptance rule for the single-layer single-line HTML exception:

- the tag must fit on one line,
- it must not contain nested block elements,
- it must not require attributes beyond `href`, `src`, `alt`, or `class`,
- if it cannot meet all of these constraints, it does not qualify and current-behavior fallback applies instead.

Implementation order within this phase: start with the cases where inline HTML most reliably improves the output, specifically `sup` and `sub`, before moving to more ambiguous structures. If problems are found in practice, revert individual cases or narrow raw-HTML passthrough behavior and fall back to a Markdown-only policy where necessary.

Required tests:

- figure policy tests
- picture-collapse tests
- video and audio fallback tests
- table GFM conversion tests
- raw-HTML passthrough verification confirming whether inline HTML survives the renderer
- translation compatibility tests confirming that fallback handling does not introduce new non-segmented containers or alter `p` / `ul` / `ol` block boundaries in article fixtures

This phase is what turns the converter from "best effort" into a readable canonicalization system instead of a lossy serializer.

### Phase 5: Consolidate fixtures, helpers, and coverage

This is a test- and tooling-consolidation phase, not the first point where tests are introduced.

Required work:

- unify fixture organization
- extract shared semantic-normalization helpers
- expand representative corpus coverage
- remove temporary or duplicated test scaffolding introduced in earlier phases

Add or consolidate golden coverage for:

- `Readability HTML -> Markdown`
- `Markdown -> Reader HTML`
- semantic round-trip normalization

At minimum, include fixtures for:

- plain text article
- article with linked lead image
- article with figure and caption
- article with responsive `picture`
- article with nested lists
- article with inline emphasis and code
- article with table

The purpose of this phase is to harden and simplify the test suite after the core behavior is already covered by earlier phase-specific tests.

## Testing Strategy

The right test target is not exact string equality of serialized HTML. The right target is normalized semantic equivalence.

Recommended checks:

- important DOM nodes still exist after round-trip
- image nodes remain image nodes
- links still wrap the correct content
- captions remain attached to the right media block
- paragraph and list counts remain stable
- translation segment extraction over rendered HTML remains stable for unchanged articles

Useful test layers:

- unit tests for node-level Markdown conversion
- golden tests for representative article fragments
- integration tests for full reader build and render

### Test implementation requirements

The converter should gain dedicated tests as part of this refactor. The previous lack of converter coverage is itself a product risk and should be treated as technical debt to retire during implementation, not after it.

Each implementation step must:

- add or update targeted tests in the same change,
- define the intended canonical Markdown shape,
- verify rendered HTML semantics after the Markdown round-trip,
- verify no regression to translation segmentation for unaffected article shapes.

### Recommended test layers in detail

#### 1. Node-level converter tests

Purpose:

- validate exact canonical Markdown output for focused HTML fragments,
- pin down escaping and fallback rules.

These should cover:

- `a > img`
- `a > em`
- `a > code`
- inline emphasis and strong text
- heading with inline formatting
- pure `img`
- `figure > img + figcaption`
- simple `picture`
- simple table to GFM
- complex table fallback

These tests should assert the exact Markdown string because canonicalization stability is part of the contract.

#### 2. Fragment round-trip tests

Purpose:

- validate that `HTML -> Markdown -> rendered HTML` preserves required semantics.

These should assert normalized DOM properties such as:

- number of `img` elements
- number of links
- whether a link wraps an image
- whether a figure still contains its caption
- whether table rows and headers remain recognizable

These tests should avoid brittle exact HTML serialization matches.

#### 3. Reader integration tests

Purpose:

- validate the full reader pipeline including persisted Markdown and final rendered output shape.

These should cover:

- `ReadabilityResult.content` fixture into `MarkdownConverter`
- rendered HTML generation via `ReaderHTMLRenderer`
- persistence-sensitive behavior where markdown is reused on subsequent builds

Where practical, they should also verify that broken persisted Markdown from an older format version is rebuilt when the format version changes.

#### 4. Translation compatibility tests

Purpose:

- ensure reader converter changes do not accidentally shift translation behavior.

These tests must operate on the final rendered HTML output, not on the Markdown intermediate form. The translate agent processes rendered HTML; assertions against Markdown alone are insufficient and can miss real regressions. The test pipeline must be: fixture HTML → `MarkdownConverter` → `ReaderHTMLRenderer` → segmentation extraction → assertion.

These should assert:

- stable `p` / `ul` / `ol` counts for unaffected fixtures,
- stable segment IDs or stable normalized segment content when the source semantics did not change,
- no accidental conversion of textual content into non-segmented raw HTML containers.

### Coverage matrix

At minimum, the suite should include the following fixture classes:

| Fixture | Exact Markdown assertion | DOM round-trip assertion | Translation compatibility |
| --- | --- | --- | --- |
| Plain article paragraphs | Yes | Yes | Yes |
| Linked lead image | Yes | Yes | Yes |
| Figure with caption | Yes | Yes | Optional |
| Responsive `picture` | Yes | Yes | Optional |
| Simple table | Yes | Yes | Optional |
| Complex table | Yes | Yes | Optional |
| Nested list | Yes | Yes | Yes |
| Inline emphasis and code | Yes | Yes | Yes |
| Mixed media paragraph | Yes | Yes | Yes |

### Phase-by-phase testing requirements

Phase 0 must add:

- layered rebuild-policy contract tests,
- version-mismatch tests for `readabilityVersion`, `markdownVersion`, and `readerRenderVersion`,
- persistence reuse tests proving cheaper downstream rebuilds do not trigger unnecessary upstream recomputation.

Phase 1 must add:

- migration tests,
- lazy-upgrade tests,
- rebuild-order integration tests,
- tests proving no startup-wide blocking migration is required.

Phase 2 must add:

- linked-image unit tests,
- linked-image round-trip tests,
- regression coverage proving URLs are not surfaced as fallback text for image links,
- translation compatibility tests verifying that `p` / `ul` / `ol` counts and segment IDs remain stable for article fixtures unaffected by this change.

Phase 3 must add:

- inline formatting canonicalization tests,
- heading inline-format tests,
- escaping tests for Markdown metacharacters,
- translation compatibility tests confirming that inline formatting changes do not alter `p` / `ul` / `ol` block boundaries or segment IDs for representative article fixtures.

Phase 4 must add:

- figure policy tests,
- picture-collapse tests,
- video and audio fallback tests,
- table GFM conversion tests,
- raw-HTML passthrough verification confirming whether inline HTML survives the renderer,
- translation compatibility tests confirming that fallback handling does not introduce new non-segmented containers or alter `p` / `ul` / `ol` block boundaries in article fixtures.

Phase 5 then consolidates fixtures and shared semantic-normalization helpers rather than introducing testing for the first time.

## How To Test With Existing Articles

For real-world regression verification, Mercury should support a controlled way to force specific articles through the reader pipeline again.

The practical lookup key is `entryId` from the `entry` table.

### Current implementation reset levels

Under the current implementation, once the target article is identified, there are two useful reset levels:

- rerender only
  - clear the rendered reader HTML cache for that `entryId`
  - use this when testing `Markdown -> Reader HTML` behavior only
- rebuild reader content
  - clear both the persisted `content` row and the rendered reader HTML cache for that `entryId`
  - use this when testing `Readability -> Markdown` changes or full reader-pipeline regressions

The reason both levels are needed is the current reader build order:

- cached rendered HTML is reused first,
- persisted `content.markdown` is reused next,
- network fetch plus `Readability` plus Markdown regeneration only runs when persisted reader content is absent.

### Target layered reset levels

After layered persistence is introduced, the preferred manual reset levels should become:

- rerender only
  - clear rendered reader HTML cache only
- rebuild Markdown and render
  - clear Markdown plus rendered reader HTML cache
  - keep cleaned `Readability` HTML
- rebuild cleaned `Readability` HTML, Markdown, and render
  - clear cleaned `Readability` HTML, Markdown, and rendered reader HTML cache
  - keep source HTML
- full rebuild from network
  - clear source HTML, cleaned `Readability` HTML, Markdown, and rendered cache

This layered reset model is one of the main reasons to persist cleaned `Readability` HTML separately.

Operational guidance:

- identify the target article through `entry`
- clear only the minimum reader data needed for the test case
- prefer article-scoped cleanup over global cleanup
- when editing the on-disk database manually, do so with the app closed or with full awareness of SQLite WAL side files

This article-scoped reset flow should be the default manual verification method for reader converter work.

## Cache and Versioning

Mercury should adopt explicit versioning for each persisted transformation layer. This is now part of the intended architecture, not an optional cleanup.

## Versioned layer model

Recommended version axes:

- `readabilityVersion`
  - validates cleaned `Readability` HTML against the current extraction and cleanup rules
- `markdownVersion`
  - validates canonical Markdown against the current `Readability HTML -> Markdown` converter rules
- `readerRenderVersion`
  - validates rendered reader HTML cache against the current renderer and output-shape rules

These versions should be independent. A renderer-only change must not force a Markdown rebuild. A Markdown-converter change must not force a source re-download.

## Concrete version constant form

Version numbers should be stored as static integer constants in a dedicated source file (`Mercury/Mercury/Reader/ReaderPipelineVersion.swift`):

```swift
enum ReaderPipelineVersion {
    /// Bump when Readability extraction or cleanup rules change.
    static let readability: Int = 1
    /// Bump when Readability-HTML-to-Markdown conversion rules change.
    static let markdown: Int = 1
    /// Bump when Markdown-to-reader-HTML rendering rules change.
    static let readerRender: Int = 1
}
```

The database stores the integer version used when each payload was built. On load, Mercury compares the stored version against the current constant. A mismatch triggers rebuild of that layer and all downstream layers.

A null or missing stored version should be treated as version 0. Version 0 always mismatches current version 1 and triggers rebuild for old rows.

Bumping a version is a one-line source change: increment the relevant constant. The change is intentional, visible in code review, and auditable through version history. No runtime configuration or separate migration step is needed to change version policy.

## Why three versions are worth having

### Benefits

- precise invalidation
  - Mercury rebuilds only the layer affected by a code change
- lower rebuild cost
  - expensive upstream work such as download and `Readability` execution can be reused
- predictable behavior
  - stale data is invalidated by design rather than by manual cleanup
- testability
  - rebuild paths can be asserted explicitly in automated tests
- operational safety
  - upgrades can happen lazily as users open articles, without full-database churn

### Costs

- one schema migration is required
- reader build logic becomes more explicit and branchy
- more persisted metadata must be maintained correctly
- version bumps need engineering discipline

These costs are acceptable because the reader pipeline is now important enough that hidden stale-data behavior is a bigger risk than the added structural complexity.

## Recommended persistence shape

The database should carry explicit validity metadata for each layer rather than inferring validity indirectly.

Recommended logical fields:

- source HTML payload
- cleaned `Readability` HTML payload
- `Readability`-extracted title and byline
- canonical Markdown payload
- `readabilityVersion`
- `markdownVersion`
- render-cache version marker for final reader HTML cache

`entry.title` and `entry.author` come from the feed XML/JSON metadata via FeedKit and are not the same as what `Readability` extracts from article HTML. `Readability` title and byline are derived from the article page DOM and can differ, particularly for `byline` which is often absent or formatted differently in feed metadata. They must be stored as part of the Readability layer so that Markdown can be rebuilt from `cleanedHtml` without re-running `Readability`.

Concrete schema additions following existing naming conventions:

`content` table (existing columns: `id`, `entryId`, `html`, `markdown`, `displayMode`, `createdAt`):

- `cleanedHtml TEXT` — stores `ReadabilityResult.content`; nullable
- `readabilityTitle TEXT` — stores `ReadabilityResult.title` at extraction time; nullable
- `readabilityByline TEXT` — stores `ReadabilityResult.byline` at extraction time; nullable
- `readabilityVersion INTEGER` — null treated as version 0
- `markdownVersion INTEGER` — null treated as version 0

`content_html_cache` table (existing columns: `entryId`, `themeId`, `html`, `updatedAt`):

- `readerRenderVersion INTEGER` — null treated as version 0

The existing `content.html` column continues to store the fetched source HTML.

Whether version metadata is stored in the same table or a companion metadata table is a schema detail. The examples above assume the simplest path of adding columns to existing tables.

## Upgrade strategy

Upgrades should be smooth and user-invisible.

Recommended policy:

- ship schema additions first
- initialize new version metadata for newly built content only
- lazily upgrade old rows when an article is opened
- avoid blocking startup or requiring a global synchronous migration of all entries

For old rows created before layered persistence exists:

- if source HTML exists, prefer rebuilding downstream layers from it without network fetch
- if source HTML is missing, fall back to network fetch only for the specific article being opened
- do not perform global eager reprocessing in the background unless a future product need justifies it

This keeps the migration effectively invisible for users while still converging the database toward the new model over time.

Version bump behavior on existing data:

- when `markdownVersion` is bumped, any row whose stored `markdownVersion` does not match is treated as stale; the next open of that article triggers Markdown rebuild from cleaned `Readability` HTML or source HTML as available
- when `readabilityVersion` is bumped, any row whose stored `readabilityVersion` does not match triggers a full Readability re-run and downstream rebuild
- when `readerRenderVersion` is bumped, any cached render record whose stored version does not match is discarded; the next open regenerates from existing valid Markdown if present
- this is the intentional design: version bumps are the primary mechanism for converging stale persisted data to the current format without manual database cleanup

## Rebuild decision rules

The reader build path should evaluate validity from cheapest reusable upstream layer downward.

Recommended decision order:

1. if rendered reader HTML cache exists for current entry and theme identity, and its stored `readerRenderVersion` matches the current version, use it
2. else if Markdown exists and `markdownVersion` matches, rerender from Markdown
3. else if cleaned `Readability` HTML exists and `readabilityVersion` matches, rebuild Markdown then rerender
4. else if source HTML exists, rerun `Readability`, then rebuild Markdown, then rerender
5. else fetch source HTML, then run the full pipeline

This ordering minimizes cost while keeping version semantics explicit.

## Rebuild failure and rollback policy

Rebuild attempts must be non-destructive. A failed rebuild must never leave persisted data in a partially updated state.

Required behavior:

- write new payload and version metadata only on full success of that layer's rebuild
- on any error during a rebuild attempt, leave all existing stored data unchanged
- emit a debug issue recording the failure, the affected layer, and the entry identifier
- do not retry automatically within the same session; the next open of the article will detect the stale version and retry naturally

This ensures:

- users always see their last known valid reader content rather than a broken intermediate state
- a persistent converter bug cannot silently corrupt stored content across the library
- once the bug is fixed and a version is bumped, all affected articles self-correct on next open

Partial-layer success policy:

- layers are committed independently wherever possible
- if Markdown rebuild succeeds but render-cache generation fails: commit the new Markdown and its version metadata, do not commit the failed render cache, emit a debug issue for the render failure
- the next open will find valid Markdown, detect a missing render cache, and regenerate render only
- this keeps failure granularity at the layer level rather than forcing a full-chain rollback on a late-stage failure

## Render cache strategy

`readerRenderVersion` is a validity marker stored alongside the cached record, not a component of the cache lookup key.

The cache lookup key is based on entry identity and effective theme identity. Finding a cached record by key is a separate concern from deciding whether that record is still valid.

Recommended behavior:

- do not include `readerRenderVersion` in the cache lookup key
- after locating a cached record by key, check whether its stored `readerRenderVersion` matches the current constant; if not, discard and regenerate
- treat version mismatch as a post-lookup validity failure, not a key miss
- avoid a separate manual cleanup path for renderer-only changes; version mismatch detection handles invalidation automatically

This keeps renderer invalidation clean and local without requiring changes to the cache key schema.

## When to bump each version

Bump `readabilityVersion` when:

- `Readability` cleanup rules change in a way that can alter cleaned article structure or media retention
- site-specific `Readability` behavior changes in a way that can alter exported cleaned HTML shape

Bump `markdownVersion` when:

- canonical Markdown output shape changes
- supported HTML-to-Markdown mappings change
- escaping or fallback rules change in a way that affects persisted Markdown

Bump `readerRenderVersion` when:

- rendered reader DOM structure changes
- renderer output wrappers or structural CSS anchors change
- HTML output changes in a way that affects downstream DOM consumers or visible rendering

Pure cosmetic token changes should continue to be handled by theme cache identity, not by `readerRenderVersion`.

## Is this necessary now

Yes.

For the current refactor, versioning is no longer a nice-to-have because:

- the converter is about to change materially,
- persisted Markdown already exists and can become stale,
- the project wants a durable database design rather than repeated manual cleanup,
- layered rebuild behavior is needed for reliable regression testing and smooth upgrades.

At this point, shipping converter improvements without explicit versioned invalidation would leave correctness dependent on manual database resets, which is not acceptable as the long-term contract.

## Recommended Non-Goals

The converter should not attempt to:

- reproduce every original website styling choice
- preserve arbitrary unsafe HTML from the source page
- optimize for byte-identical HTML output

The target is readable, structured, deterministic, and safe article content with high semantic fidelity.

## Summary

The current reader architecture is sound. The main weakness is not the use of Markdown as the canonical stored format; it is the current converter's overly lossy HTML-to-Markdown rules.

The most important policy change is:

- do not silently flatten structured content into text,
- preserve semantic structure first,
- use pure Markdown whenever possible; allow only narrow single-layer single-line HTML tags as a last resort; fall back to current behavior for complex structures rather than introducing noisy HTML.

Under that model, `Readability -> Markdown -> HTML` remains a strong long-term design rather than a compromise.
