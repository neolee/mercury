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

### CSS compatibility requirement

The custom visitor must produce the same structural HTML that the existing CSS rules in `ReaderHTMLRenderer.css(for:)` target. Review all CSS selectors before finalizing the visitor output shape. The article root is `article.reader`; all reader content sits inside it.

### Acceptance criteria

- All existing `MarkdownConverter*Tests` pass without modification (converter is unchanged).
- `test_translationCompatibility_gfmTable_renderedAsTextWithCurrentRenderer` is renamed and its assertion is updated to expect `2` segments (table no longer produces a paragraph segment).
- New test: GFM table round-trip — `<table>` HTML → Markdown → rendered HTML → `<table>` element present in output.
- `ReaderPipelineVersion.readerRenderVersion` is bumped.
- No `import Down` anywhere in the codebase.
- `./scripts/build` succeeds with zero warnings.

## Status

| Step | Status |
|---|---|
| Phase 0–4: MarkdownConverter (HTML → Markdown) | Complete |
| Phase 5: Test consolidation | Planned |
| Add swift-markdown SPM dependency | Not started — manual Xcode UI action by owner |
| Implement `MarkupHTMLVisitor` | Not started |
| Replace Down in `ReaderHTMLRenderer` | Not started |
| Remove Down dependency | Not started — manual `project.pbxproj` edit by owner |
