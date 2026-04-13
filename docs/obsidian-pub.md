# Obsidian Publish Support in Mercury

## Summary

Mercury should support a narrow, static subset of Obsidian Publish pages without introducing browser execution or WebView-based rendering.

The recommended approach is:

1. Detect Obsidian Publish shell pages from the fetched HTML.
2. Statically extract the target Markdown URL from the shell page source.
3. Fetch that Markdown directly.
4. Render the Markdown into Mercury's reader pipeline.
5. Bypass `Readability` once a valid Markdown source has been resolved.

If the page cannot be resolved with static analysis alone, Mercury should treat it as unsupported for special handling and fall back to the normal HTML pipeline.

## Chadnauseam Case

### Short conclusion

The `chadnauseam` page is not a case where `Readability` chose the wrong article candidate from a complete HTML document.

It is a source-acquisition case:

- the staged `source.html` is only an Obsidian Publish bootstrap shell
- the actual article body is not present in the HTML body
- the shell page statically declares a `preloadPage` fetch for the article Markdown
- both Swift `Readability` and Mozilla `Readability.js` fail on the same shell input for the expected reason

### Implication

This case should not drive changes to core extraction heuristics in `Readability`.

The correct fix belongs in Mercury's acquisition / source-resolution layer, not in the extraction library.

## Product Decision

### What Mercury should support

Mercury should support Obsidian Publish pages only when all of the following are true:

1. The fetched HTML can be identified as an Obsidian Publish shell page with high confidence.
2. The target content URL can be extracted from the static HTML source without executing JavaScript.
3. The target content is directly fetchable over HTTP.
4. The fetched content is recognizably Markdown or another directly renderable source format.

### What Mercury should not support

Mercury should not add a browser execution step just to support these pages.

Specifically, Mercury should not:

- run a WebView to hydrate the page
- execute arbitrary page JavaScript to discover content
- wait for client-side rendering before entering reader mode
- broaden this feature into a generic SPA rendering subsystem

If browser execution would be required, the recommendation is to drop special support and use the standard fallback behavior.

## Recommended Architecture

### Pipeline placement

This logic should run before `Readability`.

Suggested high-level pipeline:

1. Fetch raw page HTML.
2. Run source resolvers against the raw HTML and URL.
3. If a resolver succeeds, produce a normalized article source.
4. Render the resolved source into reader HTML.
5. Apply sanitization and light cleanup.
6. Skip `Readability` for this resolved source.
7. If no resolver succeeds, continue with the normal HTML + `Readability` flow.

### Why `Readability` should be bypassed

Once Mercury has resolved the original Markdown source, the application already has the article in a structured authoring format.

At that point, running `Readability` is usually unnecessary and may even be harmful:

- it solves the wrong problem
- it can discard valid content after Mercury has already found it
- it adds complexity to debugging
- it hides whether a problem came from resolution or extraction

For resolved Obsidian Publish content, Mercury should prefer:

- Markdown rendering
- sanitization
- URL normalization
- optional display-level cleanup

instead of HTML re-extraction.

## Static Resolver Design

### Detection

A resolver should activate only when strong Obsidian Publish markers are present. For example:

- `base href="https://publish.obsidian.md"`
- `window.siteInfo = { ... }`
- `window.preloadPage = fetch(...)`
- asset URLs under `publish-01.obsidian.md/access/...`

Avoid fuzzy heuristics. This should be a source-specific resolver with a narrow trigger.

### Resolution strategy

Minimal algorithm:

1. Parse the fetched HTML as text.
2. Search inline script blocks for a `preloadPage` fetch target.
3. Extract the absolute Markdown URL.
4. Fetch the Markdown.
5. Validate that the response looks like expected note content.
6. Return a resolved article source to the reader pipeline.

This should be implemented as static source analysis only. No JavaScript execution is required.

### Output shape

Mercury should represent the result as a resolved source, not as a final rendered article.

A useful internal shape would look like:

```text
ResolvedArticleSource
  kind: markdown
  sourceURL: URL
  canonicalURL: URL
  body: String
  metadata: ...
  provenance: obsidian-publish-static-resolver
```

That keeps acquisition separate from rendering and makes debugging easier.

## Rendering Expectations

Mercury should aim for a readable article first, not full visual fidelity to the original site.

The first implementation can be intentionally limited:

- title
- headings
- paragraphs
- lists
- code blocks
- normal links
- basic image handling where asset mapping is straightforward

Obsidian-specific syntax can be added incrementally:

- `![[image.png]]` embeds
- `[[internal links]]`
- vault-relative resource references

If some Obsidian-specific constructs cannot be rendered cleanly in the first pass, Mercury should still prefer partial readable output over total failure.

## Fallback Policy

If any of the following happens, Mercury should stop special handling and fall back:

- the shell page cannot be identified with confidence
- no static `preloadPage` target can be extracted
- the target fetch fails
- the target content is not renderable Markdown
- rendering would require executing client-side JavaScript

Fallback should mean:

- keep the original raw HTML path
- run the normal `Readability` flow
- accept that reader mode may fail on this page

## Non-Goals

This design does not try to solve:

- generic SPA rendering
- arbitrary JavaScript-driven content discovery
- authenticated private Obsidian Publish pages
- perfect fidelity to Obsidian's browser renderer
- a universal resolver for all client-rendered sites

## Recommended Next Step

Implement one narrow resolver in Mercury:

- name: `ObsidianPublishResolver`
- scope: static shell-page resolution only
- success condition: direct Markdown URL extracted without browser execution
- output path: resolved Markdown goes to Mercury's Markdown renderer, not to `Readability`

This keeps the feature useful, bounded, testable, and aligned with Mercury's reader-mode goals.
