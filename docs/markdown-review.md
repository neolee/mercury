# Markdown Review: Multiline `data:` Image Destinations

## Scope

This note records the review outcome for Reader content that contains image Markdown like:

```md
![alt](data:image/jpeg;base64,
AAAA
BBBB)
```

The concrete trigger was `entryId = 2802910`, whose persisted Markdown contains an inline image destination with line endings inside a `data:*;base64,` payload.

The goal of this document is to clarify:

- where the failure happens in Mercury's pipeline
- whether the persisted Markdown should be considered acceptable canonical Markdown
- where compatibility logic should live
- which normalization rules are justified as general policy vs one-off special casing

## Current Pipeline

Mercury's Reader pipeline is:

```text
Source HTML -> Readability -> cleaned HTML -> MarkdownConverter -> persisted Markdown -> ReaderHTMLRenderer -> displayed HTML
```

Current Reader rendering behavior is:

- `ReaderHTMLRenderer` parses persisted Markdown with `swift-markdown`
- `swift-markdown` is backed by `cmark-gfm`
- `MarkupHTMLVisitor` renders the parsed Markdown AST into Reader HTML

This means Mercury does not render Markdown with a tolerant custom image parser. The persisted Markdown must be structurally compatible with the parser contract chosen by the app.

## Problem Statement

In the failing article:

- the source HTML contains an `<img src="data:image/jpeg;base64,...">`
- the cleaned HTML preserves that image correctly
- the persisted Markdown also preserves the `data:` payload, including embedded line endings
- the Reader render step does not reconstruct an image node from that Markdown

The visible symptom is that the Reader displays the literal `![](...)` text instead of an `<img>`.

## Root Cause

The important distinction is:

- Mercury is not parsing an image node and then accidentally splitting it later
- the Markdown parser never recognizes the source as an image node in the first place

Once `Document(parsing:)` fails to build an `Image` node, the inline content falls back to ordinary text and soft-break nodes. `MarkupHTMLVisitor` then faithfully renders those nodes as visible text.

So the failure is not caused by `MarkupHTMLVisitor` "breaking" an already-valid image element. It happens earlier, at Markdown parse time.

## Why This Happens

`swift-markdown` follows the CommonMark / `cmark-gfm` parsing contract closely. Inline image syntax reuses link destination rules. Under that contract, line endings inside an inline destination are not parsed as part of a valid inline image destination.

Practical consequence:

- a single-line `![](data:image/jpeg;base64,AAAA)` can parse as an image
- a multi-line `![](data:image/jpeg;base64,\nAAAA)` does not parse as an image node

This does not mean the document is "invalid" in the broad Markdown sense. CommonMark treats arbitrary input as a valid document and falls back to text where a higher-level construct is not recognized. But it does mean the persisted form is not a stable canonical encoding for Mercury's chosen Markdown parser.

## Canonical Markdown Principle

The key design principle is:

> Mercury's persisted Markdown is not merely a text dump of HTML content. It is a canonical intermediate form that must round-trip through Mercury's chosen Markdown parser and renderer.

Therefore, "preserving bytes from HTML" is not sufficient by itself.

If a source HTML representation is wider than the target Markdown grammar slot, the HTML-to-Markdown boundary must canonicalize the value into a parser-stable Markdown representation.

For this case:

- HTML attribute values can contain layout line breaks
- inline Markdown image destinations cannot be relied on to preserve those line breaks as part of a parsed image node
- therefore raw HTML attribute formatting cannot be treated as already-canonical Markdown destination formatting

## Architectural Decision

### Preferred location: `cleaned HTML -> Markdown`

The cleanest fix is to canonicalize at the HTML-to-Markdown boundary, not in the Reader renderer.

Reasons:

- the persisted Markdown remains the canonical, parser-stable form
- all downstream consumers benefit, not only Reader HTML rendering
- Mercury avoids introducing a second Markdown dialect at render time
- the AST remains authoritative; the renderer does not need to recover structure from text fragments

### Rejected location: post-parse recovery

Do not attempt to recover images after Markdown parsing by scanning text nodes for a possible `![](...)` pattern.

Reasons:

- once parsing has already degraded to text, structure is gone
- this becomes a second inline parser layered on top of `swift-markdown`
- edge cases expand quickly: nested brackets, escaping, code spans, titles, reference links, and raw HTML boundaries

### Possible but not preferred: Reader-side compatibility prepass

If Mercury ever decides that persisted Markdown must retain source formatting more literally, a narrow Reader-only prepass would be possible. However, this would create a Mercury-specific compatibility dialect before `Document(parsing:)`.

That approach should be considered only if canonicalization at HTML-to-Markdown is explicitly rejected.

## General Rule vs Special Case

This issue has a general architectural meaning, but the transformation rule itself should stay narrow.

### General meaning

This is a general canonicalization problem:

- HTML source fields may allow a broader representation than Markdown syntax slots
- when Mercury serializes HTML attribute values into Markdown destinations, those values must be normalized into parser-stable Markdown form

This applies in principle to:

- `img[src]` rendered as `![](...)`
- `a[href]` rendered as `[text](...)`
- media links rendered as `[Video](...)` or `[Audio](...)`
- any future feature that injects attribute values into Markdown destinations

### Narrow transformation

The actual rewrite rule should not be broad.

Do not adopt a generic policy such as:

- "remove all line breaks from every destination"
- "strip all internal whitespace from any malformed link or image"

Those policies are too aggressive and may silently mutate non-`data:` URLs into different resources.

Instead, the justified first rule is:

- only normalize `data:*;base64,` payloads
- only remove ASCII layout whitespace inside the payload portion after the comma
- keep other destination kinds conservative unless a separate rule is explicitly justified

This is narrow enough to be safe and broad enough to capture the actual source of the observed bug.

## Why `data:*;base64,` Is a Good First Rule

`data:*;base64,` is a strong first canonicalization target because:

- the encoding already semantically tolerates line wrapping in many real-world producers
- layout line breaks are often introduced for readability or transport formatting, not content meaning
- the payload can be normalized into a single-line destination without changing Mercury's intended semantic meaning for the image

This does not automatically justify similar normalization for:

- ordinary HTTP URLs
- relative URLs
- query strings with whitespace anomalies
- arbitrary malformed destinations

Those should each require explicit review before new normalization logic is added.

## Recommended Policy

Mercury should adopt the following policy for canonical Markdown generation:

1. Persisted Markdown must be stable under Mercury's chosen parser, not merely textually derived from HTML.
2. HTML attribute values must be canonicalized when serialized into Markdown syntax positions that impose stricter structure than HTML.
3. The first normalization rule should target multi-line `data:*;base64,` destinations in image and other media-like destinations.
4. Normalization rules must be format-specific and conservative.
5. Mercury must not introduce a broad, tolerant second Markdown parser unless there is an explicit product-level decision to support a Mercury-specific Markdown dialect.

## Markdown Destination Inventory

The following current converter outputs place source attribute values into Markdown destination slots:

| Source HTML field | Markdown output shape | Destination kind | Current risk class |
|---|---|---|---|
| `img[src]` | `![alt](src)` | image destination | High |
| `picture > img[src]` | `![alt](src)` | image destination | High |
| `a[href]` | `[text](href)` | link destination | Medium |
| `a > img[href]` | `[![alt](src)](href)` | nested image + link destination | High for `src`, medium for `href` |
| `video[src]` | `[Video](src)` | link destination | Medium |
| `video > source[src]` | `[Video](src)` | link destination | Medium |
| `audio[src]` | `[Audio](src)` | link destination | Medium |
| `audio > source[src]` | `[Audio](src)` | link destination | Medium |

These are the fields that should be reviewed whenever Mercury discusses HTML-to-Markdown canonicalization.

## Canonicalization Matrix

The recommended first-pass rules are:

| Destination content kind | Normalize? | Allowed canonicalization | Rationale |
|---|---|---|---|
| `data:*;base64,` payload | Yes | Trim outer whitespace; remove ASCII layout whitespace inside payload after the first comma | Safe, specific fix for the observed parser mismatch |
| Plain HTTP / HTTPS URL | No internal rewrite | Trim outer whitespace only | Internal mutation may silently change resource identity |
| Relative URL | No internal rewrite | Trim outer whitespace only | Path semantics are sensitive to internal characters |
| Query string / fragment-heavy URL | No internal rewrite | Trim outer whitespace only | Aggressive whitespace removal can change semantics |
| Unknown or non-base64 `data:` URI | Not by default | Trim outer whitespace only unless a format-specific rule is approved | No general proof that internal whitespace folding is safe |
| Missing or empty destination | No | Emit no Markdown destination-based element | This is absence of data, not a normalization problem |

The intended meaning of "trim outer whitespace only" is:

- remove leading and trailing whitespace introduced by HTML extraction or attribute formatting
- do not rewrite internal characters
- do not attempt to rescue malformed destinations into a different URL

## Stability Classification

When a source value does not fit Mercury's chosen Markdown parser contract, classify it explicitly:

| Classification | Meaning | Action |
|---|---|---|
| Stable after normalization | A narrow, format-specific rewrite produces a parser-stable Markdown destination without changing intended semantics | Normalize and emit Markdown syntax |
| Stable as-is | The destination is already parser-stable | Emit Markdown syntax unchanged |
| Unstable and no approved rewrite | The value cannot be safely transformed into a parser-stable Markdown destination under current rules | Preserve source data elsewhere if needed, but do not invent a broad rescue rule |

For the current issue:

- multiline `data:*;base64,` image sources should be treated as `Stable after normalization`
- ordinary multiline destinations should be treated as `Unstable and no approved rewrite` unless a separate rule is explicitly approved

## Handling Rules for Unstable Inputs

When Mercury encounters a destination that is not parser-stable and has no approved narrow rewrite:

1. Do not apply a generic "remove all internal whitespace" fallback.
2. Do not add a Reader-only heuristic parser that tries to recover arbitrary `![]()` or `[]()` text into structure.
3. Treat the case as requiring an explicit format-specific decision.
4. If product requirements eventually demand support, document the new rule as a parser-compatibility extension, not as an implicit cleanup.

This keeps Mercury from gradually accumulating undocumented Markdown dialect behavior.

## Code Mapping

The current decision points in `MarkdownConverter` already align well with a destination-specific policy. The relevant implementation surface is in [Markdown.swift](/Users/neo/Code/ML/mercury/Mercury/Mercury/Reader/Markdown.swift).

### Image destinations

Current generation points:

- [Markdown.swift](/Users/neo/Code/ML/mercury/Mercury/Mercury/Reader/Markdown.swift:775) `primaryImageMarkdown(from:)`
- [Markdown.swift](/Users/neo/Code/ML/mercury/Mercury/Mercury/Reader/Markdown.swift:793) `primaryFigureMediaMarkdown(from:)`

These are the primary locations for:

- `img[src] -> ![alt](src)`
- `picture > img[src] -> ![alt](src)`
- `a > img/picture -> [![alt](src)](href)`

Recommended policy mapping:

- add image-destination canonicalization at or immediately before `primaryImageMarkdown(from:)`
- keep the rule format-specific
- do not make `primaryFigureMediaMarkdown(from:)` invent new cleanup logic; it should reuse the image and link normalization decisions already made upstream

### Link destinations

Current generation point:

- [Markdown.swift](/Users/neo/Code/ML/mercury/Mercury/Mercury/Reader/Markdown.swift:443) `renderInlineFragments(from:)`, `case "a"` at [Markdown.swift](/Users/neo/Code/ML/mercury/Mercury/Mercury/Reader/Markdown.swift:456)

This branch currently handles:

- `a[href] -> [text](href)`
- `a > img -> [![alt](src)](href)`

Recommended policy mapping:

- any future `href` destination normalization should be introduced as a dedicated helper used from this branch
- do not share a broad "sanitize any destination" helper between `href` and `src` unless the rule is explicitly valid for both
- nested linked-image output should remain composition of two independently normalized destinations:
  - image `src`
  - anchor `href`

### Video and audio destinations

Current generation points:

- block-level rendering branch:
  - `case "video"` at [Markdown.swift](/Users/neo/Code/ML/mercury/Mercury/Mercury/Reader/Markdown.swift:187)
  - `case "audio"` at [Markdown.swift](/Users/neo/Code/ML/mercury/Mercury/Mercury/Reader/Markdown.swift:204)
- inline fragment branch:
  - `case "video"` at [Markdown.swift](/Users/neo/Code/ML/mercury/Mercury/Mercury/Reader/Markdown.swift:502)
  - `case "audio"` at [Markdown.swift](/Users/neo/Code/ML/mercury/Mercury/Mercury/Reader/Markdown.swift:513)

These branches currently emit:

- `[Video](src)`
- `[Audio](src)`

Recommended policy mapping:

- if Mercury later decides to normalize media `src` values, use a dedicated media-destination helper
- both block and inline branches must share the same normalization logic to preserve canonical output consistency
- do not let block and inline media serialization drift into separate normalization policies

### Suggested helper structure

If implementation proceeds, the most maintainable helper split is:

- `canonicalImageDestination(_:)`
  - for image-like `src` values
- `canonicalLinkDestination(_:)`
  - for `href`
- `canonicalMediaDestination(_:)`
  - only if video/audio ever require distinct handling

The helpers should follow these constraints:

- each helper owns one destination family
- each helper documents which rewrites are allowed
- each helper returns the original trimmed value when no approved rewrite applies
- helpers must not silently broaden into generic malformed-Markdown recovery

### Explicit non-goal in code structure

Do not place this logic in:

- `ReaderHTMLRenderer`
- `MarkupHTMLVisitor`
- any post-parse AST repair layer

Those layers are already downstream of the parser contract. Destination canonicalization belongs in the HTML-to-Markdown serialization boundary, not in the Markdown-to-HTML renderer.

## Testing Implications

The relevant test coverage should lock three facts separately:

1. Parser fact:
   single-line `data:` image destinations parse as image nodes, multi-line ones do not.
2. Converter fact:
   multi-line `data:*;base64,` payloads from cleaned HTML are canonicalized into a single-line Markdown destination.
3. Round-trip fact:
   cleaned HTML with multi-line `data:` image payloads round-trips to Reader HTML with a rendered `<img>`.

These tests should be treated as part of the canonical Markdown contract, not as one-off regressions for a single article.

## Versioning Implication

Because this changes the HTML-to-Markdown transformation rule, the Markdown pipeline version must be bumped.

Otherwise:

- newly converted articles would behave correctly
- already persisted articles with multi-line `data:` destinations would remain broken until manually invalidated

So this is not only a runtime rendering change. It is a persisted-canonical-form change and must invalidate downstream cached Markdown and rendered HTML accordingly.

## Final Decision

The review conclusion is:

- the persisted multi-line `data:` image destination should not be treated as acceptable canonical Markdown for Mercury's current parser contract
- the failure occurs because the parser does not construct an `Image` node, not because Mercury later splits a valid image node into text
- the cleanest and most defensible fix is canonicalization at the `cleaned HTML -> Markdown` boundary
- this is a general boundary-design lesson, but the first concrete normalization rule should remain narrowly scoped to `data:*;base64,` payload folding
