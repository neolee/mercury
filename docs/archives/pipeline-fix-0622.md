# Reader Pipeline Fix: Date-Paragraph Merge Bug

**Date:** 2026-06-22  
**Entry ID:** 4155940 (maurycyz.com feed)  
**Status:** Analysis complete — awaiting approval to implement

---

## 1. Problem

Articles from maurycyz.com have their publication date (e.g. `2026-06-18`) merged directly with the first paragraph of article text, with no space or paragraph break between them:

> `**2026-06-18**Now that I have a way to run electrodes through...`

The Readability cleaned HTML has correct structure — the problem occurs during **HTML → Markdown conversion** in `MarkdownConverter`.

---

## 2. Root Cause

### 2.1 Actual HTML Structure

Inspecting `https://maurycyz.com/projects/glass/2/`:

```html
<main>
    <h1><em>Glassblowing #2: Making a tungsten lamp and (bad) vacuum diode</em></h1>
    <b title="Publication"><time>2026-06-18</time></b>
    <!-- mksite: start of content -->
    <p>Now that I have a way to run electrodes through <a href="...">glass</a>...</p>
</main>
```

The date is in `<b title="Publication"><time>2026-06-18</time></b>` — a **direct child** of `<main>` (a block container), positioned between `<h1>` and the first `<p>`.

### 2.2 Buggy Code Path

In `Markdown.swift`, `renderMarkdown(from:whitespacePolicy:)` handles the `<b>` tag:

```swift
case "strong", "b":
    return try renderInlineMarkdown(from: element)  // → "**2026-06-18**"
```

`renderInlineMarkdown` produces `**2026-06-18**` — **no trailing `\n\n`**. This is correct for inline usage inside a paragraph, but incorrect when `<b>` is a block-level child.

`renderBlockContainerMarkdown` (used for `<main>`, `<div>`, `<article>`, etc.) currently concatenates children through the generic child renderer:

```swift
private static func renderBlockContainerMarkdown(from element: Element) throws -> String {
    let content = try renderBlockChildrenMarkdown(from: element)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return content.isEmpty ? "" : content + "\n\n"
}
```

For each child of `<main>`, the outputs are simply concatenated:

| Child | Tag Case | Output |
|-------|----------|--------|
| `<h1>Title</h1>` | `"h1"` → block heading | `# Title\n\n` |
| `<b><time>date</time></b>` | `"b"` → `renderInlineMarkdown` | `**2026-06-18**` ← **no `\n\n`** |
| whitespace text node | `.discardWhitespaceOnlyTextNodes` | *discarded* |
| `<!-- comment -->` | not TextNode/Element | *(empty)* |
| `<p>Article text...</p>` | `"p"` → block paragraph | `Now that I have a way...\n\n` |

**Combined:**
```
# Title\n\n**2026-06-18**Now that I have a way to run electrodes through...\n\n
```

The `**2026-06-18**` is directly concatenated with the paragraph text — no space, no separation.

### 2.3 Why Existing Tests Don't Catch It

- `test_headerInlineContent_followedByParagraph_keepsBlockBoundary` uses `<header>` which is a known block tag — correctly adds `\n\n`
- `test_articleHeaderWithOnlyTime_isExcludedFromMarkdown` tests `<header><time>` being removed entirely
- **No test** for `<b>`, `<strong>`, `<time>`, or `<span>` as direct children of a block container

---

## 3. Scope of Impact

Any **inline-rendered element** (`<b>`, `<strong>`, `<em>`, `<i>`, `<span>`, `<time>`, `<code>`, `<a>`, etc.) appearing as a **direct child of a block child sequence** followed by a block element can exhibit this bug if the parent renderer simply concatenates child output.

Common real-world scenarios:
- Blog posts with `<strong>date</strong>` before content (maurycyz.com)
- Articles with `<time>` elements at the article level
- Any site that places metadata outside `<header>` or `<p>` tags

Affected renderer surfaces should include normal block containers such as `<main>`, `<div>`, `<article>`, and `<section>`, plus block renderers that delegate to child rendering such as `blockquote` and `figure` fallback paths.

---

## 4. Proposed Fix

### Strategy

Block elements (`<p>`, `<h1>`-`<h6>`, `<ul>`, `<ol>`, `<pre>`, `<blockquote>`, `<hr>`) all produce output ending with `\n\n`. Inline elements (`<b>`, `<strong>`, `<em>`, `<span>`, `<time>`, `<code>`, `<a>`) do not.

The fix: introduce a shared block-child sequence renderer. When iterating children in block flow, if the current child produces block output (ends with `\n\n`) and the accumulated result from previous children does not already end with `\n\n`, inject a `\n\n` separator before appending the block child.

This keeps inline children grouped conservatively while preventing a preceding inline child from being merged into the following block.

### Code Change

**File:** `Mercury/Mercury/Reader/Markdown.swift`

Add a shared helper and route block child rendering through it:

```swift
private static func renderBlockChildSequenceMarkdown(from element: Element) throws -> String {
    let children = element.getChildNodes()
    var result = ""
    var previousNonEmpty = false

    for child in children {
        let childOutput = try renderMarkdown(
            from: child,
            whitespacePolicy: .discardWhitespaceOnlyTextNodes
        )
        if childOutput.isEmpty { continue }

        let childIsBlock = childOutput.hasSuffix("\n\n")
        if previousNonEmpty && !result.hasSuffix("\n\n") && childIsBlock {
            result += "\n\n"
        }

        result += childOutput
        previousNonEmpty = true
    }

    return result
}

private static func renderBlockChildrenMarkdown(from element: Element) throws -> String {
    try renderBlockChildSequenceMarkdown(from: element)
}

private static func renderBlockContainerMarkdown(from element: Element) throws -> String {
    let content = try renderBlockChildSequenceMarkdown(from: element)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return content.isEmpty ? "" : content + "\n\n"
}
```

The shared helper should be used anywhere `MarkdownConverter` renders block-flow child sequences, including `renderBlockContainerMarkdown`, `blockquote`, and `figure` fallback rendering.

### Why the `childIsBlock` Guard?

Without the `childIsBlock` check, consecutive inline elements at block level would be forcibly separated:

```
Aggressive:   <b>Date</b><span>Author</span><p>Text</p>
              → **Date**\n\nAuthor\n\nText    ← Date and Author separated (new behavior)

Conservative: <b>Date</b><span>Author</span><p>Text</p>
              → **Date**Author\n\nText         ← Date and Author stay merged (unchanged)
```

The conservative approach **only fixes the reported bug** without introducing new separations.

---

## 5. Side Effect Analysis

12 scenarios tested — zero regressions, all expected changes verified:

| # | Scenario | Current Output | Proposed Output | Change? |
|---|----------|---------------|-----------------|---------|
| 1 | `<p>A</p><p>B</p>` — normal paragraphs | `A\n\nB` | `A\n\nB` | No |
| 2 | `<h1>T</h1><p>B</p>` — heading + paragraph | `# T\n\nB` | `# T\n\nB` | No |
| 3 | `<p>A</p><ul><li>B</li></ul>` — para + list | `A\n\n- B` | `A\n\n- B` | No |
| 4 | `<pre>x</pre><p>B</p>` — code + paragraph | `\`\`\`\nx\n\`\`\`\n\nB` | same | No |
| 5 | `<b>date</b><p>Text</p>` — **THE BUG** | `**date**Text` | `**date**\n\nText` | **Yes** ✓ |
| 6 | `<time>date</time><p>Text</p>` | `dateText` | `date\n\nText` | **Yes** ✓ |
| 7 | `<strong>B</strong><p>Text</p>` | `**B**Text` | `**B**\n\nText` | **Yes** ✓ |
| 8 | `<b>A</b><span>B</span><p>C</p>` | `**A**BC` | `**A**B\n\nC` | **Yes** (partial) |
| 9 | `<h1>T</h1><b>date</b><p>Text</p>` | `# T\n\n**date**Text` | `# T\n\n**date**\n\nText` | **Yes** ✓ |
| 10 | `<header><b>date</b></header><p>Text</p>` | `**date**\n\nText` | same | No |
| 11 | `<img src='x.jpg'><p>Text</p>` | `![x](x.jpg)\n\nText` | same | No |
| 12 | `<p>A</p><br><p>B</p>` | `A\n\n\nB` | `A\n\n\nB` | No |
| 13 | `<blockquote><b>Note</b><p>Text</p></blockquote>` | `> **Note**Text` | `> **Note**` + block-separated quoted text | **Yes** ✓ |
| 14 | `<figure><span>Caption</span><p>Text</p></figure>` fallback | `CaptionText` | `Caption\n\nText` | **Yes** ✓ |

Notes:
- `\n\n\n` sequences are collapsed to `\n\n` by existing post-processing in `markdownFromHTML`
- Scenario 8: consecutive inline elements stay merged (`**A**B`), only separated from the following block — this is the correct conservative behavior

---

## 5b. Additional Finding: Whitespace Lost Between Consecutive Inline Block-Level Children

### Problem

After fixing the inline→block boundary (section 4), a related issue surfaces for articles where the date is followed by another inline element before the first block:

| Entry ID | Structure | Bug Output |
|----------|-----------|------------|
| 4155939 | `<b><time>date</time></b> <em>[Photo]</em> <!-- --> <p><img></p>` | `**2026-06-19***[Photo]*` — no space between date and label |
| 4146606 | `<b><time>date</time></b> <a href="...">(...)</a> <!-- --> <p><img></p>` | `**2026-06-14**[(...)](...)` — no space between date and link |

Both have the structure:

```html
<main>
    <h1>Title</h1>
    <b title="Publication"><time>2026-06-19</time></b> <em>[Photo]</em>    ← two inline siblings
    <!-- mksite: start of content -->
    <p><a href="..."><img src="..."></a></p>                               ← block sibling
</main>
```

### Root Cause

The whitespace text node (` `) between `<b>` and `<em>` is a direct child of `<main>`. Under `.discardWhitespaceOnlyTextNodes`, it produces empty output and is discarded. Since both `<b>` and `<em>` produce inline output (neither ends with `\n\n`), the `childIsBlock` guard in `renderBlockChildSequenceMarkdown` lets them stay merged — but without the intervening space, they are **glued together**:

```
<b>date</b> → "**2026-06-19**"    (inline, no \n\n)
" "        → ""                  (discarded)
<em>label</em> → "*[Photo]*"     (inline, no \n\n)
→ result: "**2026-06-19***[Photo]*"   ← no space
```

This is a distinct issue from the original bug (inline→block merging). Here the boundary is **inline→inline**, and the meaningful whitespace separator between them is lost.

### Scope

Any sequence of **consecutive inline elements at block level** separated by whitespace-only text nodes will exhibit this bug:

- `<b>date</b> <em>label</em>` → `**date***label*`
- `<time>date</time> <a href="...">text</a>` → `date[text](...)`
- `<strong>A</strong> <span>B</span>` → `**A**B`

### Proposed Fix

Extend `renderBlockChildSequenceMarkdown` with a lightweight pending-separator mechanism:

1. When a **collapsible whitespace-only text node** is discarded after inline content (`!result.hasSuffix("\n\n")`), record a pending space. Reuse the existing `isIgnorableInlineWhitespaceNode(_:)` helper and require the text node to be non-empty, so only HTML-collapsible separators are restored.
2. If the next non-empty child is **also inline** (`!childIsBlock`), consume the pending space and insert `" "` before appending the child.
3. If the next non-empty child is a **block**, ignore the pending space (we add `"\n\n"` instead).
4. If the whitespace text node appears **after a block** (`result.hasSuffix("\n\n")`), do not record a pending space (whitespace after blocks is not meaningful).
5. Empty comments and other empty non-text nodes must not clear the pending separator, so `<b>A</b> <!-- --> <em>B</em>` still preserves the space.

Updated `renderBlockChildSequenceMarkdown`:

```swift
private static func renderBlockChildSequenceMarkdown(from element: Element) throws -> String {
    let children = element.getChildNodes()
    var result = ""
    var previousNonEmpty = false
    var pendingInlineSeparator = false

    for child in children {
        let childOutput = try renderMarkdown(
            from: child,
            whitespacePolicy: .discardWhitespaceOnlyTextNodes
        )

        if childOutput.isEmpty {
            // A whitespace text node between inline elements is a meaningful
            // separator that should be preserved as a single space.
            if previousNonEmpty,
               !result.hasSuffix("\n\n"),
               let textNode = child as? TextNode,
               textNode.getWholeText().isEmpty == false,
               isIgnorableInlineWhitespaceNode(child) {
                pendingInlineSeparator = true
            }
            continue
        }

        let childIsBlock = childOutput.hasSuffix("\n\n")

        if previousNonEmpty && !result.hasSuffix("\n\n") {
            if childIsBlock {
                result += "\n\n"
            } else if pendingInlineSeparator {
                result += " "
            }
        }

        result += childOutput
        previousNonEmpty = true
        pendingInlineSeparator = false
    }

    return result
}
```

### Scenario Trace

| # | Scenario | Result | Check |
|---|----------|--------|-------|
| A | `<b>date</b> <em>label</em> <p>Text</p>` | `**date** *label*\n\nText` | ✓ space preserved |
| B | `<b>date</b> <!-- --> <p>Text</p>` | `**date**\n\nText` | ✓ pending space ignored before block |
| C | `<b>A</b><span>B</span>` (no whitespace) | `**A**B` | ✓ no pending space |
| D | `<p>A</p> <p>B</p>` (whitespace between blocks) | `A\n\nB` | ✓ whitespace after block not recorded |
| E | `<b>A</b> <b>B</b>` (two inline with space) | `**A** **B**` | ✓ space preserved |
| F | `<h1>T</h1> <p>B</p>` | `# T\n\nB` | ✓ whitespace after block not recorded |
| G | ` <p>A</p>` (leading whitespace) | `A` | ✓ no pending (prevNonEmpty=false) |
| H | `<b>A</b> <!-- --> <em>B</em>` | `**A** *B*` | ✓ comment does not clear pending space |

All scenarios in section 5 remain unaffected: the `childIsBlock` and `result.hasSuffix` guards ensure the pending space is only consumed before inline children.

---

## 6. Files to Modify

| File | Change |
|------|--------|
| `Mercury/Mercury/Reader/Markdown.swift` | Add shared block-child sequence rendering and reuse it from block-flow paths |
| `Mercury/MercuryTest/MarkdownConverterCorpusTests.swift` | Add exact Markdown and round-trip test cases for block-level inline elements |

`ReaderPipelineVersion.markdown` may need to change because this updates the persisted HTML-to-Markdown transformation contract. The version bump decision is intentionally left for release/pipeline policy review rather than hard-coded in this proposal.

---

## 7. New Test Cases

```swift
@Test
func test_boldAsDirectChildOfBlockContainer_followedByParagraph_addsBlockBoundary() throws {
    let html = """
    <div><b>Date: 2026-06-18</b><p>Article text.</p></div>
    """
    let markdown = try convertMarkdown(html)
    #expect(
        markdown == "**Date: 2026-06-18**\n\nArticle text.",
        "Bold element at block level must be separated from following paragraph, got: \(markdown)"
    )
}

@Test
func test_timeAsDirectChildOfBlockContainer_followedByParagraph_addsBlockBoundary() throws {
    let html = """
    <div><time>2026-06-18</time><p>Article text.</p></div>
    """
    let markdown = try convertMarkdown(html)
    #expect(
        markdown == "2026-06-18\n\nArticle text.",
        "Time element at block level must be separated from following paragraph, got: \(markdown)"
    )
}

@Test
func test_strongAsDirectChildOfBlockContainer_followedByParagraph_addsBlockBoundary() throws {
    let html = """
    <article><strong>Breaking:</strong><p>Story details.</p></article>
    """
    let markdown = try convertMarkdown(html)
    #expect(
        markdown == "**Breaking:**\n\nStory details.",
        "Strong element at block level must be separated from following paragraph, got: \(markdown)"
    )
}

@Test
func test_consecutiveInlineElementsAtBlockLevel_stayMerged() throws {
    let html = """
    <div><b>Date</b><span>Author</span><p>Text.</p></div>
    """
    let markdown = try convertMarkdown(html)
    #expect(
        markdown == "**Date**Author\n\nText.",
        "Consecutive inline elements at block level should stay merged, separated only from block, got: \(markdown)"
    )
}

@Test
func test_headingFollowedByInlineFollowedByParagraph_addsBoundaryBeforeParagraph() throws {
    let html = """
    <main>
      <h1>Title</h1>
      <b title="Publication"><time datetime="2026-06-18">2026-06-18</time></b>
      <p>First paragraph.</p>
    </main>
    """
    let markdown = try convertMarkdown(html)
    #expect(
        markdown == "# Title\n\n**2026-06-18**\n\nFirst paragraph.",
        "Maurycyz-style article: date must be separated from first paragraph, got: \(markdown)"
    )
}

@Test
func test_headingFollowedByInlineFollowedByParagraph_survivesRoundTripAsSeparateBlocks() throws {
    let html = """
    <main>
      <h1>Title</h1>
      <b title="Publication"><time datetime="2026-06-18">2026-06-18</time></b>
      <p>First paragraph.</p>
    </main>
    """
    let rendered = try roundTrip(html)
    #expect(
        try countElements("article.reader > h1", in: rendered) == 1,
        "Heading must remain a heading after round-trip"
    )
    #expect(
        try countElements("article.reader > p", in: rendered) == 2,
        "Publication date and first body paragraph must render as separate paragraphs, got: \(rendered)"
    )
}

@Test
func test_boldWhitespaceEmFollowedByParagraph_preservesSpaceBetweenInlineChildren() throws {
    let html = """
    <main>
      <h1>Title</h1>
      <b title="Publication"><time datetime="2026-06-19">2026-06-19</time></b> <em>[Photo]</em>
      <!-- mksite: start of content -->
      <p><a href="big.jpg"><img src="small.jpg" alt="Photo"></a></p>
    </main>
    """
    let markdown = try convertMarkdown(html)
    #expect(
        markdown == """
        # Title

        **2026-06-19** *[Photo]*

        [![Photo](small.jpg)](big.jpg)
        """,
        "Whitespace between inline children and block boundary before linked image must be preserved, got: \(markdown)"
    )
}

@Test
func test_boldWhitespaceLinkFollowedByParagraph_preservesSpaceBetweenInlineChildren() throws {
    let html = """
    <main>
      <h1>Title</h1>
      <b title="Publication"><time datetime="2026-06-14">2026-06-14</time></b> <a href="/tags/astro">(Astronomical Images)</a>
      <!-- mksite: start of content -->
      <p><a href="big.jpg"><img src="small.jpg" alt="Astronomical image"></a></p>
    </main>
    """
    let markdown = try convertMarkdown(html)
    #expect(
        markdown == """
        # Title

        **2026-06-14** [(Astronomical Images)](/tags/astro)

        [![Astronomical image](small.jpg)](big.jpg)
        """,
        "Whitespace between bold and link block-level children must be preserved, got: \(markdown)"
    )
}

@Test
func test_boldWhitespaceEmFollowedByLinkedImage_survivesRoundTripAsSeparateBlocks() throws {
    let html = """
    <main>
      <h1>Title</h1>
      <b title="Publication"><time datetime="2026-06-19">2026-06-19</time></b> <em>[Photo]</em>
      <!-- mksite: start of content -->
      <p><a href="big.jpg"><img src="small.jpg" alt="Photo"></a></p>
    </main>
    """
    let rendered = try roundTrip(html)
    #expect(
        try countElements("article.reader > p", in: rendered) == 2,
        "Date/label and image must render as separate paragraphs, got: \(rendered)"
    )
    #expect(
        try firstElementText("article.reader > p:first-of-type", in: rendered) == "2026-06-19 [Photo]",
        "First paragraph must preserve the space between date and label, got: \(rendered)"
    )
    #expect(
        try countElements("article.reader > p:nth-of-type(2) img", in: rendered) == 1,
        "Second paragraph must contain the linked image, got: \(rendered)"
    )
}

@Test
func test_whitespaceBetweenInlineChildrenAfterBlock_notPreserved() throws {
    let html = """
    <div><p>Block.</p> <b>Inline</b></div>
    """
    let markdown = try convertMarkdown(html)
    #expect(
        markdown == "Block.\n\n**Inline**",
        "Whitespace after block must not be preserved before inline child, got: \(markdown)"
    )
}

@Test
func test_adjacentInlineElementsAtBlockLevel_withoutWhitespace_stayMerged() throws {
    let html = """
    <div><b>Date</b><span>Author</span><p>Text.</p></div>
    """
    let markdown = try convertMarkdown(html)
    #expect(
        markdown == "**Date**Author\n\nText.",
        "Adjacent inline elements without whitespace must stay merged, got: \(markdown)"
    )
}
```
