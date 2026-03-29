# Mercury — Feed Parser Repair Plan

## Problem

Mercury previously mapped Atom entry URLs using the first link in `feedEntry.links`, effectively:

```swift
feedEntry.links?.first?.attributes?.href
```

That is incorrect for feeds such as Blogger Atom feeds where the first link may be a comments feed, edit endpoint, or self endpoint rather than the article page.

This caused two classes of bad historical data:

1. `entry.url` could be persisted as a non-article URL.
2. Reader source content and downstream Reader pipeline state could be built from Atom/XML instead of article HTML.

The fix has two separate responsibilities and they must remain separate:

- current parsing correctness for new syncs
- one-time historical repair for previously persisted bad data

---

## Current Parsing Rule

`SyncService` remains responsible only for current feed parsing and sync persistence.

For Atom entries, Mercury must select the article URL using the new link-selection rule:

1. `rel="alternate"` with `type="text/html"` or `type="application/xhtml+xml"`
2. `rel="alternate"` with no `type`
3. any link with `type="text/html"`
4. fallback to the first available `href`

This rule affects only current mapping of incoming Atom entries to `Entry.url`.

---

## Historical Repair Boundary

Historical repair must not live in `SyncService`.

Introduce a dedicated `FeedParserRepairUseCase` responsible for:

- deciding whether a synced existing feed requires parser verification
- comparing the old URL-selection behavior against the new behavior
- repairing historical bad entry URLs when required
- clearing stale Reader pipeline data derived from wrong URLs
- emitting repair diagnostics/events for `Debug Issues`

This use case is only for existing feeds that are being re-synced.

It is not used for:

- newly added feeds
- first sync after OPML import
- first sync of starter feeds imported during bootstrap
- any path with no sync behavior

---

## Feed Parser Versioning

Add a new nullable `feed.feedParserVersion` column.

Add a dedicated source file:

- `Feed/FeedParserVersion.swift`

```swift
enum FeedParserVersion {
    static let current = 1
}
```

Historical rows naturally have `NULL`.

This version tracks whether a feed has already been verified against the current feed-parser repair logic.

### Version update rules

For existing-feed sync verification:

- if verification finds no URL-selection differences, set `feedParserVersion = FeedParserVersion.current`
- if verification finds differences and repair completes successfully, set `feedParserVersion = FeedParserVersion.current`
- if repair fails, do not update `feedParserVersion`

The first rule is required so feeds that are already clean do not pay the verification cost repeatedly on every sync.

---

## Verification Strategy

Verification runs only after a successful sync of an existing feed.

Given a parsed Atom feed already in memory, `FeedParserRepairUseCase` performs:

1. For each Atom entry, compute:
   - old algorithm URL: first link `href`
   - new algorithm URL: current preferred article URL
2. If all comparable entries produce the same URL under both algorithms:
   - do nothing else
   - mark `feedParserVersion` current
3. If at least one entry differs:
   - enter repair flow

This is a feed-level gate: one differing entry is enough to trigger repair for that feed.

---

## Repair Rules

Repair uses the current parsed Atom entry as the source of truth for the old/new link candidates.

An existing entry is considered repairable when all of the following hold:

1. the synced Atom entry has a stable `guid` / `atom:id`
2. an existing row matches `(feedId, guid)`
3. the stored URL differs from the new preferred URL
4. the stored URL is consistent with the old parser behavior for that same Atom entry

For each repairable entry:

1. update `entry.url` to the new preferred URL
2. delete the row from `content`
3. delete rows from `content_html_cache`

User-state fields must not be modified:

- `isRead`
- `isStarred`
- `createdAt`

If repair encounters a URL uniqueness conflict with another entry in the same feed, that specific entry is skipped and surfaced diagnostically.

---

## Sync API Design

Keep the existing `FeedSyncUseCase.sync(...)` API unchanged.

Add a new sibling API:

- `FeedSyncUseCase.syncWithVerify(...)`

`syncWithVerify(...)`:

1. runs the normal sync flow
2. only for already-existing feeds, runs `FeedParserRepairUseCase`
3. records repair diagnostics / debug issues
4. updates `feedParserVersion` when verification succeeds or when repair succeeds

`sync(...)` remains the path for:

- newly added feeds
- newly imported OPML feeds
- starter feeds imported during bootstrap

`syncWithVerify(...)` is the path for:

- user-triggered sync on existing feeds
- scheduled / automatic sync
- bootstrap when syncing feeds that already existed before bootstrap

---

## Debug Issue Projection

`FeedParserRepairUseCase` emits structured repair events.

Projection to `Debug Issues` remains centralized in `AppModel+Sync`.

Expected event shapes:

- repair started
- repair completed
- repair skipped
- repair failed

This keeps the repair implementation isolated while preserving real-time diagnostics for background data mutation.

---

## Performance Goals

Verification must be:

- feed-local
- in-memory first
- one-time per parser version
- batched at the database layer

Implementation guidance:

- reuse the parsed Atom DOM already fetched during sync; never reparse or refetch solely for verification
- skip verification entirely when `feedParserVersion == FeedParserVersion.current`
- compare old/new URL candidates in memory before touching the database
- only query the database for entries whose old/new URLs differ
- apply repair in a single write transaction per feed

## Efficient Verification and Repair

The verification path should be implemented as a feed-local two-phase pipeline:

### Phase 1: in-memory diff scan

Given a parsed Atom feed already in memory:

1. iterate the entry list once
2. compute, for each entry:
   - `guid`
   - `oldURL` using the legacy first-link rule
   - `newURL` using the current preferred-link rule
3. normalize both URLs through the same entry URL normalization path
4. append the entry to `diffCandidates` only when:
   - `guid` exists
   - both URLs are comparable
   - `oldURL != newURL`

If `diffCandidates` is empty:

- do not touch `entry` or `content` tables
- update only `feed.feedParserVersion`
- finish immediately

This gives the cheap fast path:

- one in-memory pass over the parsed DOM
- one feed-row update

### Phase 2: batched database verification

If `diffCandidates` is non-empty:

1. batch-load existing rows by `(feedId, guid)`
2. batch-load possible URL conflicts by `(feedId, newURL)`
3. build the final repair plan in memory

The final repair plan only includes entries where:

- the persisted `entry.url` still matches the legacy `oldURL`
- the target `newURL` is not already owned by another entry in the same feed

Entries are skipped when:

- the row no longer exists
- the persisted URL no longer matches the legacy wrong URL
- another entry already owns the target URL

### Phase 3: single-transaction repair

Apply all accepted repairs in one write transaction:

1. update `entry.url`
2. delete affected rows from `content`
3. delete affected rows from `content_html_cache`
4. update `feed.feedParserVersion` only if the repair phase completed without error

This keeps the expensive path bounded to:

- one parsed DOM scan
- one batched read for matching entries
- one batched read for URL conflicts
- one write transaction per affected feed

### Stability rules

To keep repair safe:

- only Atom feeds participate
- only entries with stable `guid` values participate
- only rows that still look like legacy-parser output are mutated
- repair failure leaves `feed.feedParserVersion` unchanged so the next sync can retry
- successful clean verification also upgrades the version so clean feeds are not rechecked on every sync

## Implementation Shape

To minimize churn and keep orchestration centralized:

- keep `FeedSyncUseCase.sync(...)` unchanged
- add `FeedSyncUseCase.syncWithVerify(...)`
- `syncWithVerify(...)` reuses the same single-feed sync machinery as `sync(...)`
- only `syncWithVerify(...)` calls `FeedParserRepairUseCase`
- `sync(...)` remains the path for new-feed first syncs and import flows

The internal single-feed sync machinery should return enough context for verification without refetching or reparsing:

- synced `Feed`
- parsed `FeedKit.Feed`
- whether the feed existed before this sync flow

That allows verification to run immediately against the in-memory parsed feed and keep all repair orchestration in one place.

---

## Testing Scope

Tests should be split by responsibility:

### `SyncService`

- Atom link selection prefers article `alternate` HTML links over comments/self/edit links

### `FeedParserRepairUseCase`

- verification marks clean feeds as current version
- differing old/new parser results trigger repair
- repair updates `entry.url`
- repair deletes `content` and `content_html_cache`
- repair preserves user state
- repair conflict handling is stable
- version update rules are correct

### `FeedSyncUseCase`

- `sync(...)` does not trigger repair verification
- `syncWithVerify(...)` does trigger verification for existing feeds
- existing-feed sync paths and new-feed sync paths are routed correctly
