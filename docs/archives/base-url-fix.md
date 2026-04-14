# Reader Document Base URL Fix

## Background

Some feeds publish entry URLs that are not the final document URL used by the website.

Example shape:

- feed entry URL: `https://example.com/posts/article`
- final document URL after redirect: `https://example.com/posts/article/`

If the article HTML contains relative media or links such as:

```html
<img src="media/header.png">
```

then the Reader pipeline must resolve that relative URL against the actual document URL, not blindly against the feed entry URL.

Today Mercury passes `entry.url` into `Readability(html:baseURL:)`. That is incorrect for redirected documents and causes broken absolute URL resolution inside `Readability`.

There is a related problem in Web mode: `WKWebView` can end up repeatedly reloading when the requested URL and the final redirected URL differ only by canonicalization such as a trailing slash.

This document defines the production fix for both problems.

---

## Goals

- Resolve relative URLs in `Readability` against the actual document base URL.
- Persist that base URL so local `Readability` reruns remain correct.
- Avoid heuristic URL rewriting such as "append `/` when the path has no extension".
- Repair old entries that already have a stored Reader pipeline but do not have a persisted document base URL.
- Keep old-entry repair logic in a dedicated module instead of burying it inside the normal Reader pipeline.
- Fix Web mode so redirected pages do not get stuck in a reload loop.

---

## Non-Goals

- Do not use `<link rel="canonical">` as the base for resolving relative resources.
- Do not rewrite every redirected final URL back into `entry.url`.
- Do not require debug-only actions to repair production data.
- Do not add broad speculative network probes that run for every entry outside the normal Reader lifecycle.

---

## Core Principle

Mercury must distinguish between:

- the entry URL used to identify and open an article: `entry.url`
- the document base URL used to resolve relative resources in the fetched HTML: `content.documentBaseURL`

These are often equal, but they are not guaranteed to be equal.

`documentBaseURL` is a property of the fetched source document, not a permanent property of the feed item itself.

---

## Data Model

Add a new nullable column to `content`:

- `documentBaseURL: String?`

Recommended model field:

```swift
var documentBaseURL: String?
```

Recommended semantics:

- This field stores the trusted base URL associated with the currently persisted `Content.html`.
- It is updated whenever a new source document is fetched and persisted.
- It is also allowed to be backfilled from a valid HTML `<base href>` found in persisted source HTML.
- It must not be permanently written from a low-confidence fallback that came only from `entry.url`.

Rationale:

- A fetch response URL is a high-confidence signal.
- A valid HTML `<base href>` is a high-confidence signal.
- `entry.url` is only a fallback input, not a trustworthy persisted base for redirected documents.

---

## Trusted Base URL Sources

The document base URL should be resolved in this priority order:

1. HTML `<base href>` if present and valid
2. final `URLSession` response URL
3. `entry.url` as an in-memory fallback only

Important rule:

- Only sources 1 and 2 are persisted into `content.documentBaseURL`.
- Source 3 may be used for the current build attempt, but it must not be written back as `documentBaseURL`.

This prevents Mercury from permanently cementing a known-bad fallback for old entries.

---

## Normal Reader Pipeline Changes

### Fetch result model

Replace the current "HTML only" fetch return shape with a structured result:

```swift
struct ReaderFetchedDocument {
    let html: String
    let responseURL: URL?
}
```

`fetchSourceHTML(url:)` should become a document fetch helper that returns both:

- decoded HTML
- the final response URL from `URLSession`

### Base URL resolution helper

Add a dedicated helper, for example:

- `ReaderDocumentBaseURLResolver`

Responsibilities:

- inspect HTML for `<base href>`
- resolve relative `<base href>` against the final response URL when needed
- fall back to the final response URL
- fall back in memory to the entry URL when necessary

Suggested API:

```swift
struct ReaderResolvedDocumentBaseURL {
    let url: URL
    let isPersistable: Bool
}
```

or equivalent.

### Full fetch flow

During `fetchAndRebuildFull`:

1. prepare the article URL from `entry.url`
2. fetch source HTML and capture `responseURL`
3. resolve the document base URL using the resolver
4. persist:
   - `content.html`
   - `content.documentBaseURL` if the resolved URL is persistable
5. call `Readability(html: baseURL:)` using the resolved document base URL

### Local rerun flow

During `rerunReadabilityAndRebuild`:

1. if `content.documentBaseURL` exists and parses as a URL, use it
2. else try to extract a valid `<base href>` from `content.html`
3. if successful, use it and backfill `content.documentBaseURL`
4. else fall back in memory to `entry.url`

Important rule:

- If step 4 is reached, do not persist that fallback value as `documentBaseURL`.

---

## Old Entry Repair Strategy

This project must not rely on debug-only actions to repair old entries.

Old entries are entries that already have:

- persisted `content.html`
- possibly complete Reader pipeline data
- but no `content.documentBaseURL`

### Repair architecture

The repair logic must live in a dedicated module, not be scattered across the normal pipeline.

Recommended source location:

- `Mercury/Mercury/Reader/UseCases/ReaderDocumentBaseURLRepairUseCase.swift`

Recommended responsibilities:

- detect whether an entry qualifies for repair
- attempt local backfill from persisted HTML `<base href>`
- if local backfill fails, perform a targeted source refetch to recover the real document base URL
- refresh the Reader pipeline when repair succeeds

This matches the architectural intent of dedicated repair modules such as feed parser repair.

### Repair trigger policy

The normal Reader flow may trigger the repair use case, but must not inline the repair logic itself.

Suggested trigger conditions:

- the selected entry has persisted `content.html`
- `content.documentBaseURL == nil`
- no repair for this entry is already running

Suggested repair flow:

1. check persisted HTML for `<base href>`
2. if found, persist `documentBaseURL` and stop
3. otherwise perform a targeted article fetch
4. capture the final response URL
5. recompute `documentBaseURL`
6. persist refreshed `content.html` and `documentBaseURL`
7. rerun `Readability -> Markdown -> Reader HTML`

### UX policy for repair

Repair should be self-healing and low-disruption.

If the entry already has displayable Reader output:

- show the currently available content immediately
- run the repair in the background
- refresh the displayed Reader content when the repaired pipeline finishes

Do not block the initial presentation of old but usable content just because a repair is needed.

### Persistence rule during repair

The repair use case may persist `documentBaseURL` only when it comes from:

- a valid HTML `<base href>`
- a fresh fetch response URL

The repair use case must not persist `entry.url` as the repaired `documentBaseURL`.

---

## `entry.url` Update Policy

This fix should not broadly change `entry.url` semantics.

Keep the existing safe normalization:

- continue upgrading `http -> https` where Mercury already does so

Do not add broad "persist final response URL into `entry.url`" behavior as part of this fix.

Possible future enhancement:

- a narrowly scoped canonicalization pass for same-origin, trailing-slash-only normalization

That is out of scope for this change.

---

## Web Mode Fix

The current Web mode uses:

- `WebView(url: entry.url)`
- reload logic based on comparing `nsView.url` with the requested URL

This is fragile for redirected pages because:

- requested URL: `https://example.com/posts/article`
- actual loaded URL: `https://example.com/posts/article/`

Those URLs differ, so SwiftUI updates can cause repeated reload attempts.

### Required fix

Do not use the current `webView.url` as the identity for deciding whether a new top-level load is necessary.

Instead, store the last explicitly requested top-level URL inside the `WebView` coordinator, for example:

```swift
var lastRequestedTopLevelURL: URL?
```

Reload policy:

- if the newly requested URL differs from `lastRequestedTopLevelURL`, perform a new `load`
- otherwise do nothing

This allows the web view to follow server redirects naturally without being forced back to the pre-redirect URL on every update.

---

## Schema Migration

Add a migration after the current Reader pipeline migrations:

- alter `content`
- add nullable `documentBaseURL`

No eager backfill migration is required.

Reason:

- old rows cannot be repaired correctly from SQL alone
- trusted backfill requires HTML parsing and, in some cases, a network fetch
- this is application-level repair logic, not a database migration concern

---

## Testing Plan

### Base URL resolver tests

Add dedicated tests for:

- final response URL with trailing slash is used when no `<base href>` exists
- valid `<base href>` overrides response URL
- relative `<base href>` resolves against response URL correctly
- invalid `<base href>` falls back to response URL
- fallback to `entry.url` is marked non-persistable

### Reader pipeline tests

Extend pipeline tests to cover:

- full fetch persists `documentBaseURL` from the final response URL
- local rerun prefers persisted `documentBaseURL`
- local rerun backfills from persisted HTML `<base href>`
- local rerun without trusted base uses `entry.url` only in memory
- old entry repair fetches and repairs when `documentBaseURL` is missing

### Web mode tests

Add or extend tests to verify:

- redirected web URLs do not trigger repeated reloads
- repeated SwiftUI updates with the same requested URL do not reload the page again

---

## Recommended Implementation Order

1. add `content.documentBaseURL`
2. add `ReaderFetchedDocument`
3. add `ReaderDocumentBaseURLResolver`
4. wire normal `fetchAndRebuildFull` to persist and use `documentBaseURL`
5. wire local reruns to prefer persisted `documentBaseURL`
6. add `ReaderDocumentBaseURLRepairUseCase`
7. integrate repair triggering from the normal Reader flow without inlining repair logic there
8. fix Web mode top-level reload identity
9. add tests
10. run `./scripts/build` and `./scripts/test`

---

## Decision Summary

- Add `content.documentBaseURL`.
- Use trusted document base URL semantics, not feed entry URL semantics.
- Persist the base URL only from `<base href>` or final fetch response URL.
- Do not persist `entry.url` as a repaired `documentBaseURL`.
- Implement old-entry repair as a dedicated Reader repair use case module.
- Let the normal Reader flow trigger repair, but keep repair logic out of the normal pipeline implementation.
- Fix Web mode reload identity so redirected pages display reliably.
