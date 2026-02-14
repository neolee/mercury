# Stage 2 — Batch Read-State Actions + Search (Plan)

> Date: 2026-02-12
> Scope: Traditional RSS Reader only (exclude AI features)

Stage 2 focuses on completing Phase C (P2) tasks:
- Task 2: Batch read-state actions
- Task 4: Search

Task 3 (star/save-for-later) is explicitly out of scope for Stage 2.

## 1. Current Baseline (What Exists Today)

### 1.1 Data model and schema
- `Feed` table stores `unreadCount`.
- `Entry` table stores `isRead`, plus `title` and `summary`.
- `Content` table stores `markdown` and `html` per entry.

### 1.2 Entry list querying
- The entry list query already supports:
  - Feed scope: a specific feed (`feedId != nil`) or `All Feeds` (`feedId == nil`)
  - Unread-only filtering (`isRead == false`)
  - Unread pinned-keep behavior via `keepEntryId` injection

### 1.3 Unread interaction contract
Unread filter behavior has a strict contract and is implemented using an explicit ephemeral state:
- `unreadPinnedEntryId`

Any batch action and search behavior must not regress the contract.

## 2. Answers to the Two Key Questions

### 2.1 Batch actions: one button is enough (for Stage 2)

In the current app, the visible entry list and the loaded entry list are the same thing.
There is no pagination or background partial loading of the middle list.

Therefore, for Stage 2, a single action is sufficient:
- `Mark List as Read`: mark every entry currently loaded in the middle list as read

Notes:
- This naturally respects current filters. If `Unread` is enabled, this marks the unread subset.
- The older split between `Mark Visible as Read` and `Mark All as Read` becomes meaningful only when:
  - pagination or partial loading is introduced, or
  - the product needs a destructive global action like `Mark Feed as Read` (entire feed history) or `Mark All Feeds as Read`.

Stage 2 intentionally keeps the interaction minimal: one button, one meaning.

### 2.2 Searching `Content.markdown`: feasible without FTS, but has limits

It is feasible to search `Content.markdown` using a plain SQL query in SQLite:
- join `entry` and `content` on `content.entryId = entry.id`
- filter with `LIKE` on `content.markdown`

This does not require Full Text Search (FTS) to be functionally correct.

However, it has important limitations:
- Performance: `LIKE '%term%'` performs a full scan and does not scale well.
- Coverage: `content.markdown` exists only after reader-build has run for an entry.
  - For entries never opened in reader mode, `content.markdown` may be `NULL`.
  - This means body search is inherently partial unless the app pre-builds content in the background.
- Result quality: no ranking, no stemming, no tokenization rules.

Recommendation for Stage 2:
- Start with a fast, predictable baseline search over `Entry.title` + `Entry.summary`.
- Optionally add an advanced mode: include `Content.markdown` when available.
- Plan an evolution path to `FTS5` when scale, speed, and ranking become real requirements.

## 3. Codebase Assessment: High-Value Refactoring Opportunities

This section lists improvements that increase reuse and reduce future regressions.
Stage 2 includes three refactor steps, executed in order:
1. Unify unread count recalculation and introduce `EntryListQuery`.
2. Consolidate sync paths to reduce duplication and future regressions.
3. Optimize `All Feeds` feed title mapping via a join-based query.

### 3.1 Unread count recalculation is duplicated
Unread count updates exist in multiple places:
- `FeedStore.updateUnreadCount(for:)`
- `SyncService.recalculateUnreadCount(for:)` and `SyncService.recalculateUnreadCounts()`

Risk:
- Batch read-state operations will introduce yet another copy unless unified.

Stage 2 recommendation:
- Introduce a single entry point (a small use case or helper) for unread count refresh.
- At minimum, batch operations should use one consistent mechanism to recompute:
  - per-feed unread counts for affected feeds
  - `totalUnreadCount`

### 3.2 Entry list query construction is becoming a feature hub
`EntryStore.loadAll(...)` already handles:
- feed scope
- unread filter
- pinned keep behavior

Task 4 adds search, and Task 2 adds batch actions based on the loaded list.

Stage 2 recommendation:
- Introduce a light query object such as `EntryListQuery` to keep the query-building logic in one place.
- Keep UI components dumb: UI passes query state, store executes query.

### 3.3 Sync paths are partially split (consolidate in Stage 2)
Sync is now driven by `TaskQueue` and `FeedSyncUseCase`, but `SyncService` still contains older orchestration methods.

Risk:
- Two sync orchestration paths increase maintenance cost and make correctness fixes harder.

Stage 2 recommendation:
- Route bootstrap and sync orchestration through the same use case-driven path.
- Keep `SyncService` focused on per-feed operations (fetch/parse/dedupe) and shared primitives.

### 3.4 `All Feeds` feed title mapping should be join-friendly
For `All Feeds`, the store currently loads feeds separately and maps titles in memory.

Risk:
- With search and frequent reloads, repeated reads and in-memory mapping can become a performance bottleneck.

Stage 2 recommendation:
- Replace the feed-title mapping with a join-based query that fetches the needed feed title alongside entries.
- Keep the UI-facing shape stable so this remains an internal optimization.

## 4. Task 2 — Batch Read-State Actions (Implementation Plan)

### 4.1 UX definition (Stage 2)
One action only:
- `Mark List as Read`

Behavior rules:
- Marks every entry currently loaded in the entry list as read.
- Clears `unreadPinnedEntryId` (to avoid violating the unread contract).
- Reloads entries for the current selection and current filters.

### 4.2 Data layer changes
Add a batch API to `EntryStore`:
- `markRead(entryIds:isRead:)`

Implementation notes:
- Use chunking for `IN (...)` queries to avoid SQLite variable limits.
- Run updates inside a transaction.
- Update the in-memory `entries` array so UI reflects changes immediately.

### 4.3 Unread counts refresh strategy
After marking entries read:
- Refresh unread counts for affected feeds.

Implementation options (pick one for Stage 2):
1. Minimal: call `FeedStore.updateUnreadCount(for:)` for each affected feedId (deduped).
2. Better: add `FeedStore.updateUnreadCounts(for feedIds: [Int64])` with a single DB pass.

After per-feed updates:
- set `totalUnreadCount = feedStore.totalUnreadCount`

### 4.4 AppModel API
Add an AppModel method that the UI calls:
- `markLoadedEntriesAsRead()`

It should:
- gather loaded entry IDs from `entryStore.entries`
- call the `EntryStore` batch update
- refresh unread counts and totals
- trigger a list reload via the existing reload mechanism

### 4.5 UI integration
Add one button/menu item in the entry list header:
- `Mark List as Read`

Placement should follow macOS patterns:
- a button with a short label, or a menu in the entry list header

### 4.6 Verification checklist
- In `Unread` mode, pressing the action empties the list (except selection rules).
- In `All Feeds`, it marks the mixed list and refreshes the `All Feeds` badge.
- Unread pinned keep behavior does not persist after the batch action.

## 5. Task 4 — Search (Implementation Plan)

### 5.1 UX definition (Stage 2)
- Place the search field in the top toolbar (title bar), between the left title and right-side actions.
- Keep the entry list header compact; do not add a search field there.
- Provide a small scope switch near the search field:
  - `This Feed`
  - `All Feeds`
- Search combines with the unread filter.

Pinned keep compatibility:
- When `searchText` is non-empty, pinned keep injection must be disabled.
  - otherwise the list can contain an entry that does not match search.

### 5.2 Query strategy
Stage 2 search uses a conservative, non-FTS baseline:

Default search targets (only):
- `Entry.title`
- `Entry.summary`

Stage 2 explicitly avoids searching large content fields (`Content.markdown`/cleaned body) to reduce scan cost and memory pressure.

### 5.3 Implementation steps
1. Add `searchText` and search scope state in `ContentView`.
2. Add toolbar search UI (search field + scope switch) in `ContentView`.
3. Add a debounced reload on `searchText`/scope change.
4. Extend `EntryStore.loadAll(...)` / `EntryListQuery` to accept `searchText`.
5. Update query building:
   - apply feed scope
   - apply unread filter
   - apply search filter
   - disable pinned keep injection when `searchText` is non-empty
6. Validate performance on a medium dataset.

### 5.4 Performance guardrails before FTS
- Keep search on short fields only (`title` + `summary`) in Stage 2.
- Apply debounce on input changes.
- Apply a result cap for search queries to keep UI responsive.
- Continue using indexed narrowing predicates (`feedId`, `isRead`, ordering columns) before text matching.
- Keep large cleaned/markdown fields in separate storage and out of normal list queries.

### 5.5 Evolution path to `FTS5`
When ready to evolve:
- Add an `FTS5` virtual table for entries and content.
- Keep UI and query state unchanged.
- Swap implementation behind the same search API.

## 6. Proposed Execution Order (Stage 2)

1. Refactor step 1: unify unread count recalculation + introduce `EntryListQuery`.
2. Refactor step 2: consolidate sync paths.
3. Refactor step 3: join-based `All Feeds` feed title mapping optimization.
4. Implement Task 2 (batch read-state actions).
5. Implement Task 4 (search).

## 7. Failure Surfacing Policy (Implemented)

To avoid noisy UX during large imports and background sync, Stage 2 applies a strict separation between user-facing popups and diagnostic logs.

### 7.1 Non-fatal feed-level sync failures
- For task kinds `bootstrap`, `syncAllFeeds`, and `syncFeeds`:
  - do not show user popup alerts
  - keep detailed records in `Debug Issues`
- For task kind `importOPML`:
  - feed-level failures such as unsupported feed format, TLS handshake failures, and ATS secure-connection failures are treated as non-fatal
  - these failures are logged to `Debug Issues` and should not interrupt import with popup alerts

### 7.2 Fatal import failures (popup required)
Only file-level or workflow-level failures should surface as popup alerts, for example:
- OPML parsing fails (invalid file structure/content)
- file access/write permission failures
- storage or transaction failures that prevent import progress

### 7.3 Status bar behavior
- Non-fatal feed-level failures should not replace normal bottom-left aggregate status text.
- Aggregate counters and last-sync information remain visible unless a truly fatal state is reached.

## 8. Implementation Update (2026-02-12)

This document section records the final closure work completed before continuing Stage 2 feature development.

### 8.1 Failure policy centralization
- Added `FailurePolicy.swift` as the single source of truth for:
  - feed sync error classification (`unsupportedFormat`, `tlsFailure`, `atsPolicy`, `other`)
  - popup surfacing decision for task failures
  - permanent unsupported-feed decision during import/bootstrap
- Removed duplicated keyword/rule checks from:
  - `AppModel+Sync.swift`
  - `AppModel+ImportExport.swift`
  - `TaskQueue.swift`

### 8.2 Current user-facing behavior
- `bootstrap`, `syncAllFeeds`, `syncFeeds`: failures are logged to `Debug Issues`, no popup alert.
- `importOPML` feed-level failures (unsupported format, TLS, ATS): logged to `Debug Issues`, no popup alert.
- Popup alerts are reserved for import workflow/file-level failures that require user action.

### 8.3 Logging and diagnostics
- Feed sync failures include structured context lines (`source`, `feedId`, `feedURL`, error category/domain/code).
- Additional request diagnostics are captured for difficult network-policy cases to support deeper troubleshooting.

