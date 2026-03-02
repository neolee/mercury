# Sidebar Projection Refactor Plan

Date: 2026-03-02
Status: Proposed
Scope: Feed/Tag sidebar data flow and refresh consistency

## Motivation

The current sidebar counter refresh logic is split across four independent mechanisms, all driven by the same underlying `entry` table state:

1. **`totalUnreadCount`** — maintained by manual reassignment (`totalUnreadCount = feedStore.totalUnreadCount`) at six call sites in `AppModel+Feed.swift`. Any new read-state write path that forgets to call this goes silently wrong.
2. **`totalStarredCount` / `starredUnreadCount`** — driven by a GRDB `ValueObservation` in `AppModel.startStarredCountsObservation()`. This is the only counter that is truly observation-driven today.
3. **Per-feed unread badges** — maintained by in-memory push via `feedStore.updateUnreadCounts(for:)` after each write, also from `AppModel+Feed.swift`.
4. **Tag counters** — pull-refreshed through view-level triggers: `refreshToken`, `task(id:)`, and `TagListViewModel.loadNonProvisionalTags()`.

This split causes observable inconsistencies:

- Starred counters update automatically; all other counters depend on write-site discipline.
- Tag unread badges can lag unless a specific UI-triggered refresh path fires.
- New entry points (background updates, agent writes, future features) can silently miss one or more of paths 1, 3, and 4.

The system currently works, but the maintenance cost is high because consistency depends on manually remembering every trigger point at every write site.

## Goals

1. Establish a single source of truth for all sidebar counters: aggregate feed counts, per-feed unread badges, starred counts, and tag counts.
2. Make refresh behavior data-driven (database observation), not write-site-driven.
3. Keep UI semantics already confirmed:
   - Tag row title: `Name (usageCount)` where `usageCount` is the count of entries associated with the tag.
   - Tag right badge: `unreadCount` (unread entries associated with the tag).
   - Visibility rule: when total tag count exceeds the provisional-hidden threshold, hide provisional tags.
4. Remove ad-hoc token wiring, manual counter assignments, and duplicated refresh paths.
5. Remove `TagListViewModel`; move its responsibilities to the projection store and local view state.
6. Improve long-term maintainability and extensibility for future sidebar features (tag management menus, additional counters, grouping).

## Non-Goals

- No redesign of the sidebar visual layout.
- No change to tag assignment semantics (`usageCount`, `isProvisional` transition rules).
- No change to feed/entry query semantics for content list filtering.
- No change to the write paths themselves; only the read/observation side is touched.

## Design Overview

### 1) Introduce a unified sidebar projection contract

Add a dedicated contract that models all sidebar counter data:

- Aggregate feed counters: `totalUnread`, `totalStarred`, `starredUnread`
- Per-feed unread badges: a map or array of `(feedId, unreadCount)` pairs
- Tag rows: `tagId`, `name`, `normalizedName`, `isProvisional`, `usageCount`, `unreadCount`
- Visibility policy type: `SidebarTagVisibilityPolicy`

`usageCount` in the tag projection row is the same value currently stored in `tag.usageCount` — the count of entries associated with that tag. It is not a separate computation.

The visibility policy holds the provisional-hidden threshold as an internal constant (currently 30). The view layer does not need to know the threshold value; it only consumes the already-filtered tag list from the projection.

This contract defines what sidebar data means, independent of any specific view.

### 2) Introduce a `SidebarCountStore`

Create an observable store that owns one GRDB `ValueObservation` and publishes a complete sidebar projection.

Key properties:

- Initialized with only a `DatabaseManager` reference (no dependency on `AppModel` or any UseCase).
- Backed by a single `ValueObservation` over `entry`, `feed`, `tag`, and `entry_tag` tables.
- Computes all counters and applies the tag visibility policy within the observation.
- Publishes `@Published var projection: SidebarProjection` consumed by the UI.

Result: any DB mutation affecting unread state or tag relations automatically updates all sidebar data with no manual write-site bookkeeping.

The name `SidebarCountStore` follows the existing `FeedStore` / `EntryStore` naming convention while distinguishing it from CRUD stores — it is observation-only and performs no writes.

### 3) Make `AppModel` the owner of `SidebarCountStore`

`AppModel` instantiates `SidebarCountStore` in its `init`, alongside `feedStore` and `entryStore`.

In Phase C, the following are removed from `AppModel`:
- `starredCountsObservation` and `startStarredCountsObservation()` — superseded by `SidebarCountStore`.
- `@Published var totalUnreadCount`, `totalStarredCount`, `starredUnreadCount` — replaced by fields in `SidebarCountStore.projection`.

### 4) Remove `TagListViewModel`; move responsibilities to store and view state

`TagListViewModel` currently owns three categories of responsibility:

- **Data** (`tags`, `unreadCounts`): moves to `SidebarCountStore.projection`.
- **Visibility policy** (provisional-hidden threshold): moves to `SidebarCountStore`.
- **Local UI state** (`searchText`, `isLoading`): replaced by `@State var tagSearchText: String` directly in `SidebarView`. The `isLoading` flag is not preserved; the view renders its empty-state placeholder when the projection tag list is empty.

Tag search filtering is applied as a `@State`-derived computed property over `projection.tags` (client-side, in-memory). This keeps `SidebarCountStore` stateless and avoids needing to restart the observation on search text changes. Given that tag counts in normal usage will not exceed a few hundred, in-memory filtering is the correct trade-off.

`TagListViewModel.swift` is deleted in Phase B.

### 5) Refactor `SidebarView` to projection-driven rendering

- Accept `SidebarCountStore` (or its `projection`) as input instead of individual counter parameters and a `refreshToken`.
- Remove all `.task(id: refreshToken)` and `.task(id: sidebarSection)` reload triggers.
- Keep only local UI state: `@State var tagSearchText`, selection bindings, section picker.
- Render feed and tag counters directly from `projection`.
- Per-feed badge values come from `projection.feedUnreadCounts` rather than `feed.unreadCount` pushed via `feedStore`.

### 6) Clean up write-site counter maintenance in `AppModel+Feed.swift`

After the projection store is active:

- Remove all six manual `totalUnreadCount = feedStore.totalUnreadCount` assignments.
- Remove `feedStore.updateUnreadCounts(for:)` / `feedStore.updateUnreadCount(for:)` calls made solely to keep the in-memory feed list's `unreadCount` fields current for badge display. Write paths keep their domain write logic; they drop the sidebar-synchronization side effects.
- Remove `tagSidebarRefreshToken` and both `tagSidebarRefreshToken += 1` sites from `ContentView` (lines 233 and 446).

## File-Level Change Plan

1. Add `Mercury/Mercury/Feed/SidebarCountContracts.swift`
   - Define `SidebarProjection` struct, `SidebarFeedUnreadItem`, `SidebarTagItem`, and `SidebarTagVisibilityPolicy`.

2. Add `Mercury/Mercury/Feed/SidebarCountStore.swift`
   - Implement `SidebarCountStore`: GRDB `ValueObservation`, projection publication, visibility policy application.

3. Update `Mercury/Mercury/App/AppModel.swift`
   - Add `let sidebarCountStore: SidebarCountStore` and initialize it in `init`.
   - In Phase C: remove `starredCountsObservation`, `startStarredCountsObservation()`, and the three `@Published` aggregate counter properties.

4. Update `Mercury/Mercury/Feed/Views/SidebarView.swift`
   - Replace individual counter parameters and `refreshToken` with projection input.
   - Add `@State var tagSearchText: String = ""`.
   - Remove all `TagListViewModel` usage and `.task(id:)` reload triggers.
   - Derive filtered tag list from `projection.tags` filtered by `tagSearchText`.

5. Delete `Mercury/Mercury/Feed/Views/TagListViewModel.swift`

6. Update `Mercury/Mercury/App/Views/ContentView.swift`
   - Remove `@State var tagSidebarRefreshToken` and both `+= 1` sites (at current lines 233 and 446).
   - Pass `sidebarCountStore` (or `appModel.sidebarCountStore.projection`) into `SidebarView`.

7. Update `Mercury/Mercury/Feed/AppModel+Feed.swift` (Phase C cleanup)
   - Remove all manual `totalUnreadCount = feedStore.totalUnreadCount` assignments.
   - Remove `feedStore.updateUnreadCounts(for:)` calls that exist only to maintain badge state.
   - Retain all domain write logic (marking entries read, updating starred state, etc.).

8. Update `Mercury/Mercury/Core/Database/FeedStore.swift` (Phase C cleanup)
   - Reevaluate whether `updateUnreadCounts(for:)` / `updateUnreadCount(for:)` / `totalUnreadCount` remain needed once per-feed badge data is owned by `SidebarCountStore`.

9. Add tests: `Mercury/MercuryTest/SidebarCountStoreTests.swift`
   - Validate projection correctness for read-state mutations and tag mutations.
   - Validate visibility policy behavior at and around the threshold boundary.

10. Update documentation as needed:
    - `docs/tags-v2-tech-contracts.md`
    - `docs/tags-v2-phases.md` (if checklist scope changes)

## Implementation Phases

### Phase A: Introduce projection infrastructure

- Add contracts and `SidebarCountStore`.
- Add store tests.
- No UI migration yet; existing paths remain fully operational.

Exit criteria:

- Projection updates correctly for read-state and tag mutations in tests.
- On an identical database snapshot, each projection field value matches the corresponding value produced by the existing manual read paths (equivalence baseline).

### Phase B: Migrate sidebar rendering

- Refactor `SidebarView` to consume projection input.
- Update `ContentView` wiring to pass projection from `AppModel`.
- Delete `TagListViewModel.swift`.
- Keep current user-facing behavior unchanged.

Exit criteria:

- All four counter types (aggregate feed, per-feed badges, starred, tag) refresh consistently from projection, with no manual token triggers.
- `TagListViewModel` is fully removed with no remaining references.

### Phase C: Remove legacy refresh paths

- Remove `starredCountsObservation` from `AppModel`.
- Remove `@Published` aggregate counter properties from `AppModel`.
- Remove manual `totalUnreadCount` assignments from `AppModel+Feed.swift`.
- Remove `feedStore.updateUnreadCounts(for:)` badge-maintenance calls.
- Remove `tagSidebarRefreshToken` and both `+= 1` sites from `ContentView`.
- Reassess `FeedStore` helper methods that no longer have callers.

Exit criteria:

- No sidebar counter logic depends on write-site assignments or view-triggered refresh hooks.
- No dangling references to removed properties or methods.

## Testing Strategy

1. Unit tests for projection correctness (`SidebarCountStoreTests`):
   - Single entry read/unread toggle updates `totalUnread`, the affected feed's per-feed badge, and the relevant tag `unreadCount`.
   - Batch read/unread updates propagate all three counter types correctly.
   - Tag association add/remove updates tag `usageCount` and `unreadCount`.
   - Starring an entry updates `totalStarred` and `starredUnread`.

2. Visibility policy tests:
   - Total tags at or below threshold: provisional tags included in projection.
   - Total tags above threshold: provisional tags excluded from projection.
   - Threshold boundary behavior is deterministic.

3. Search filter tests (view-layer, not store-layer):
   - `projection.tags` filtered by non-empty `tagSearchText` returns only matching rows.
   - Empty `tagSearchText` returns full projection tag list.

4. Integration-level sanity (existing or new):
   - Sidebar feed and tag badges remain in sync after reader actions and list-level read actions.

## Risks and Mitigations

- **Risk**: `SidebarCountStore` observation duplicates or conflicts with remnant observations in `AppModel` or `FeedStore` during the migration window.
  - **Mitigation**: remove legacy observations explicitly in Phase C; verify in tests that only one observation is active per metric after cleanup.

- **Risk**: the unified projection query joins `entry`, `feed`, `tag`, and `entry_tag` and may have higher per-fire cost than individual targeted queries.
  - **Mitigation**: keep query targeted and ensure relevant columns are indexed; benchmark against a realistic dataset (hundreds of feeds, thousands of entries, hundreds of tags) before shipping Phase B.

- **Risk**: Translation agent writes to `entry` and `translation_result` per segment during active runs — potentially dozens of DB writes per article — each of which will fire the `SidebarCountStore` observation.
  - **Mitigation**: GRDB `ValueObservation` with `.async(onQueue:)` scheduling coalesces rapid successive changes before dispatching to the main queue, limiting UI update frequency in practice. Verify this behavior holds under a simulated translation run as part of Phase A testing. If coalescing is insufficient, consider a debounce on the published value.

- **Risk**: migration churn in `SidebarView` and `ContentView` introduces regressions.
  - **Mitigation**: complete Phase A with full test coverage before touching any view code in Phase B.

## Definition of Done

The refactor is complete when:

- All four sidebar counter types (aggregate feed, per-feed badges, starred, tag) are driven exclusively by `SidebarCountStore.projection`.
- No write path in `AppModel+Feed.swift` manually updates any sidebar counter.
- No view-level token or `task(id:)` reload hook drives sidebar data refresh.
- `TagListViewModel` is deleted with no remaining references.
- `starredCountsObservation` and the three legacy `@Published` aggregate counter properties are removed from `AppModel`.
- Existing user-visible behavior is unchanged except for improved consistency.
- Tests cover projection correctness, visibility policy, and search filtering.
