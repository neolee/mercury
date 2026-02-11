# Stage 1 Review — Current Progress and Next Plan (Non-AI RSS Reader)

> Date: 2026-02-11
> Scope: Traditional RSS Reader only (exclude AI features)

## 1. Current Progress Summary

Stage 1 plan in `docs/stage-1.md` is generally implemented:
- GRDB data layer and migrations are in place.
- Feed/Entry/Content CRUD and state stores are working.
- OPML import/export, feed sync, deduplication, read/unread updates, three-pane UI are present.
- Readability-based cleaning and reader mode rendering are integrated.
- Build verification passes (`./build`).

Current state can be considered: **core flow available, but not yet product-complete** for a robust traditional RSS reader.

---

## 2. Key Gaps and Risks

## 2.1 P0 Data Safety / Reliability (Must Fix First)
- Sync failure can delete feed records in current logic.
  This can turn transient network/parse failures into destructive data loss.

## 2.2 P1 Progressive UX + Async Infrastructure (Highest Priority after P0)

Large OPML import currently feels blocking:
- Parse OPML
- Insert/merge feeds
- Fetch each feed
- Parse entries
- Write DB

All of this mostly completes before the user sees meaningful UI updates, causing poor perceived performance.

Need two linked upgrades:
- Progressive UI updates: show newly imported feeds and incoming entries incrementally.
- Reusable async task queue: a unified task execution layer for import/sync/reader-build/background jobs.

This is the most important capability upgrade after data safety, because the app will increasingly depend on many concurrent async workflows.

## 2.3 P2 Functional Completeness (Traditional RSS baseline)
- Missing global timeline (`All Feeds`) and unread filtering.
- Missing batch operations (mark all read, mark feed read).
- Missing basic search (title/summary/content index strategy).
- Missing star/save-for-later.

## 2.4 P3 Engineering Quality
- `AppModel` currently owns too many responsibilities.
- Automated tests are missing (unit/integration/regression).
- Dependency pinning strategy should be stabilized for release predictability.

---

## 3. Recommended Implementation Priority

## Phase A (P0) — Data Safety Hardening
Goal: no destructive side effects from transient sync errors.

Tasks:
1. Remove destructive delete-on-sync-failure path.
2. Add per-feed sync error state (`lastError`, `lastFailedAt`, `retryCount`).
3. Add retry/backoff policy and user-visible recoverability.
4. Add migration if new fields are needed.

Acceptance:
- No feed is deleted due to network/parser failure.
- Failures are visible and recoverable with retry/sync-now.

## Phase B (P1) — Progressive Import/Sync + Unified Async Task Queue
Goal: immediate UI feedback and reusable async execution model.

Tasks:
1. Introduce `TaskQueue` abstraction:
   - Priority lanes (e.g. userInitiated/background)
   - Controlled concurrency
   - Cancellation
   - Progress/event stream
   - Error propagation policy
2. Introduce `TaskRecord` model (in-memory first, optionally persisted):
   - id/type/state/progress/message/startedAt/finishedAt
3. Refactor OPML import flow to pipeline:
   - Parse OPML quickly
   - Insert feeds in batches and publish UI updates
   - Enqueue per-feed sync jobs
   - Enqueue per-entry processing jobs
4. Update UI binding:
   - Sidebar/feed list updates incrementally
   - Entry list updates per feed incrementally
   - Surface task progress and failures

Acceptance:
- Importing large OPML shows feed list growth progressively.
- Entries appear progressively without waiting full completion.
- User can continue browsing and interacting during import/sync.
- Queue is reused by at least OPML import and manual sync.

## Phase C (P2) — Traditional Reader Completeness
Goal: complete baseline expected from a non-AI RSS app.

Tasks:
1. `All Feeds` virtual feed + unread filter.
2. Batch read-state actions.
3. Star/save-for-later.
4. Search (start from title/summary, then evolve to FTS).

Acceptance:
- Daily reading workflow can be finished entirely inside app without workarounds.

## Phase D (P3) — Maintainability and Release Readiness
Goal: sustainable velocity and predictable quality.

Tasks:
1. Split oversized app model responsibilities (sync/import/reader rendering/job orchestration).
2. Add tests:
   - OPML parser
   - feed dedup rules
   - read/unread counters
   - sync failure handling
   - queue behavior (ordering/cancel/retry)
3. Dependency and release hardening.

Acceptance:
- Critical flows have automated regression coverage.

---

## 4. Suggested Execution Order (Actionable)

1. P0 safety fixes (immediately).
2. Build `TaskQueue` skeleton + progress channel.
3. Migrate OPML import to progressive pipeline.
4. Migrate manual/auto sync to same queue.
5. Add missing traditional reader features (All/Unread/Batch/Search/Star).
6. Add tests and stabilize architecture.

---

## 5. What to Start Next (after your confirmation)

First implementation package I recommend:
1. Remove destructive sync delete path.
2. Add minimal queue primitives (`enqueue`, `cancel`, `events`).
3. Refactor OPML import into incremental feed insert + queued per-feed sync.
4. Add UI progress panel for queue tasks.

This package gives the largest UX and reliability improvement with the least product risk.

---

## 6. Unread Filter Interaction Contract (Implemented Baseline)

To avoid confusing list behavior and regressions, `Unread filter` now follows a strict interaction contract:

1. `Unread` list should only contain unread entries by default.
2. A currently selected entry may be temporarily kept visible after being marked read, only while it remains the active selection in the current unread session.
3. Once selection moves to another entry, the previously selected read entry must be removed from unread list.
4. Switching feed must clear any temporary kept entry.
5. Toggling unread filter on/off must clear any temporary kept entry.
6. No cross-feed or cross-session carry-over of a previously kept read entry is allowed.

Implementation note:
- Use an explicit ephemeral state (`unreadPinnedEntryId`) for temporary keep behavior.
- Do not implicitly derive keep behavior from `selectedEntryId` during generic reloads.
- Preserve behavior only through explicit keep parameter on unread reload path.
