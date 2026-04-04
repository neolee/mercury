# Markdown Converter

## Background

Mercury persists Reader content in canonical Markdown. The converter path is:

```text
Source HTML -> Readability -> cleaned HTML -> MarkdownConverter -> persisted Markdown
```

This document covers the HTML -> Markdown side only. It is separate from `docs/markdown-engine.md`, which records the later Markdown -> Reader HTML renderer migration.

## Goal

Freeze the `MarkdownConverter` contract before further inline refactoring so whitespace and wrapper behavior stop drifting case by case.

## Inline Serialization Contract

### Scope

These rules apply when `MarkdownConverter` serializes inline content inside:

- paragraphs
- headings
- list item inline text
- table cells
- inline wrappers such as `a`, `em`, `strong`, `del`, `sup`, `sub`, `code`, and inline `img`

### Core invariant

Inline serialization must be **DOM-fragmentation invariant**.

If two HTML fragments produce the same browser-visible inline text and inline semantics, they must serialize to the same canonical Markdown even when the DOM is split differently across `span`, `a`, `em`, or whitespace-only text nodes.

Examples:

- `<span>foo </span><a>bar</a>`
- `<span>foo</span> <a>bar</a>`
- `foo<a> bar</a>`

These must all serialize to canonical Markdown with exactly one visible space between `foo` and the linked `bar`.

### Whitespace classes

For inline serialization, whitespace is divided into two classes:

- **Collapsible ASCII whitespace**: space, tab, newline, carriage return, and DOM whitespace-only text nodes that browsers collapse in normal flow.
- **Non-collapsible semantic whitespace**: `&nbsp;` and other Unicode spacing characters whose preservation can affect meaning or wrapping behavior.

### Inline whitespace rules

1. Inside normal inline flow, any run of collapsible ASCII whitespace between two visible inline fragments serializes to exactly one ASCII space.
2. Leading and trailing collapsible ASCII whitespace at the block boundary is dropped.
3. Non-collapsible semantic whitespace must be preserved exactly and must not be downgraded to ASCII space.
4. Inline serialization must not depend on whether the separating whitespace came from:
   - a text node,
   - wrapper-internal text,
   - a sibling whitespace-only node, or
   - line breaks in the source HTML.
5. Inline joins happen in one normalization step after child rendering; sibling nodes must not each make independent whitespace decisions that leak DOM shape into canonical Markdown.

### Wrapper boundary rules

Inline wrappers must operate on **core content only**.

Rules:

1. For wrappers such as `a`, `em`, `strong`, `del`, `sup`, and `sub`, collapsible leading and trailing ASCII whitespace belongs to the surrounding inline flow, not to the wrapper payload.
2. The wrapper syntax must surround only the core visible content.
3. Boundary whitespace that was adjacent to wrapped content must be emitted outside the wrapper syntax.
4. If a wrapper contains only collapsible ASCII whitespace and no visible content, it contributes no wrapper syntax and only participates in normal whitespace joining.
5. If a link has no visible content after boundary normalization, fallback behavior may use the destination text, but that fallback must not invent or delete surrounding spaces.

Examples:

- `<a> just tried</a>` -> ` [just tried](...)`
- `<a>it </a><em><a>was</a></em><a> an April Fool’s</a>` -> `[it](...) _[was](...)_ [an April Fool’s](...)`

### Inline image rules

Inline image serialization must distinguish inline and block contexts.

Rules:

1. A bare `img` in inline flow serializes as inline Markdown image syntax without forcing paragraph breaks.
2. An image-only paragraph may still serialize as a standalone image block separated by blank lines at the paragraph level.
3. `a > img` in inline flow serializes as inline nested Markdown image syntax without forcing paragraph breaks.
4. `figure` remains a block construct and may continue to emit standalone media plus caption blocks.

This means `foo <img ...> bar` must remain one paragraph after round-trip and must not gain synthetic blank lines from the `img` node alone.

### Inline code rules

Inline code spans are verbatim inline payloads and must not reuse generic wrapper behavior.

Rules:

1. The serializer must choose a backtick fence length that is safe for the code payload.
2. If the code payload contains backticks, the emitted fence must be longer than the longest contiguous backtick run in the payload.
3. Boundary collapsible ASCII whitespace outside the code span participates in normal inline joining; whitespace inside the code payload remains verbatim.

### Canonicalization priority

When canonical Markdown readability conflicts with preserving browser-visible inline semantics, preserving semantics wins.

In practice:

- do not remove spaces that separate visible inline fragments
- do not force spaces where the browser would not render any
- do not move semantic whitespace into or out of verbatim payloads such as inline code
- do not let wrapper-specific trimming alter sibling boundary behavior

## Required Regression Matrix

Future `MarkdownConverter` changes must keep the following cases green:

1. plain text + leading-space link + plain text
2. trailing-space link + emphasized link + leading-space link
3. adjacent links separated by whitespace-only nodes
4. `span`-fragmented text vs unwrapped text producing identical Markdown
5. mixed inline text with inline `img`
6. image-only paragraph vs image inline in a sentence
7. inline code containing backticks
8. `&nbsp;` or equivalent non-collapsible whitespace adjacent to wrappers

These cases should be encoded as exact-Markdown and round-trip DOM assertions rather than renderer-only snapshots.

## Implementation Steps

Keep the implementation sequence short and test-driven:

1. Add the missing regression cases from the matrix before touching `Markdown.swift`, especially inline `img`, inline code with backticks, and semantic whitespace near wrappers.
2. Split inline serialization into two phases:
   - child rendering produces structured inline fragments
   - one final join step normalizes sibling boundaries and whitespace
3. Move wrapper handling (`a`, `em`, `strong`, `del`, `sup`, `sub`) onto the shared boundary-normalization path so wrapper-local trimming stops deciding sibling spacing.
4. Separate inline media serialization from block media serialization so `img` and `a > img` do not inject blank lines when used inline.
5. Give inline code its own fence-selection helper and keep its payload verbatim.
6. Re-run the converter corpus tests and `./scripts/build`, then verify a few persisted real-world entries with `Re-run Pipeline: Markdown`.
