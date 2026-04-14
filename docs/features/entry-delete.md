# Entry Delete Feature Design and Implementation Guide

To address issues such as duplicated feed items or inappropriate content, Mercury introduces a single-entry "delete" feature. To balance RSS sync semantics with local storage reclamation, we are adopting a hybrid strategy: a **tombstone mechanism (soft delete) combined with hard deletion of associated data**.

## Part I. Conceptual Design

## 1. Core Strategy: Soft Delete + Hard Delete

- **Semantics and Interaction**: The UI should explicitly convey to the user that this is a "Delete" operation. It is irreversible, and the article will no longer be visible once removed.
- **`entry` Table (Tombstone)**: Introduce an `isDeleted` (Boolean) field in the `entry` table as a soft-delete marker. This prevents the parser from re-inserting the article as "new" when it inevitably appears again in subsequent feed refreshes.
- **Associated Tables (Physical Cleanup)**: To free up disk space and ensure no orphaned data remains, when marking an `entry` as soft-deleted, perform a hard delete (`DELETE`) on the corresponding `entryId` records in the following tables:
  - `content`
  - `content_html_cache`
  - `agent_task_run`
  - `summary_result`
  - `translation_result`
  - `entry_tag`
  - `tag_batch_entry`
  - `tag_batch_assignment_staging`
  - `entry_note`
- **Retained Records**:
  - `llm_usage_event`: Keep these records. Token consumption and API invocation logs are historical billing facts that actually occurred, and they do not need to (and should not) be erased when an article is deleted.

Implementation note:
- The list above should remain limited to entry-scoped rows. Run-scoped batch-tagging tables such as `tag_batch_new_tag_review` and `tag_batch_apply_checkpoint` should not be partially edited in v1; if the target entry is part of an active batch lifecycle, deletion should be blocked instead of trying to repair batch state in place.

## 2. Cancellation Timing and Cleanup Sequence (Best Practice)

To prevent UI crashes, "zombie" state updates, and data races, the deletion operation must strictly follow this execution order:

1. **UI Focus Reset and Transfer**
   - **Routing logic**: Align with the "mark read/unread" behavior. When the deleted `Entry` is the currently selected article in the reader, the system should first attempt to select the **next entry**. If there is no next entry, fall back to the **previous entry**. If it is the only item in the list, set `selectedEntryId` to `nil`.
2. **Abort Agents and Background Tasks**
   - Immediately after navigating away from the target `Entry`'s UI focus, invoke `TaskCenter` and `AgentRuntimeEngine` to cancel all active tasks bound to this `entryId` (including summaries, translations, and tag operations, whether running or queued). This completely severs network requests and state callbacks associated with this record.
3. **Database Transaction**
   - After the first two steps (UI detachment, task abortion) are complete, open a GRDB `db.write` or `db.inTransaction` scope.
   - Safely execute the `DELETE` operations for the 9 tables listed above, and finally execute `UPDATE entry SET isDeleted = 1 WHERE id = ?` within this single transaction.

Implementation note:
- In the current codebase, this step needs a concrete coordinator because cancellation APIs are split across queue task IDs, `AgentRuntimeEngine` owners, and `AppModel`'s panel-tagging task map.
- For active batch-tagging lifecycle entries, the safer v1 policy is to reject deletion before this sequence starts.

**Preventing Unintended Auto-Read Triggers on Passive Selection**

Whether an automatic jump occurs due to the current article being deleted (hopping to the next), or an unread entry is passively selected due to a filter change, this passive selection **must not** trigger the "automatically mark article as read after a few seconds" timer.

Under the current architecture, the "auto-mark as read" timer must be strictly tied to explicit user click/selection behaviors. With the introduction of automatic list jumping, we must explicitly distinguish `{ userInitiated: Bool }` within the selection update flow. This intercepts the auto-read timer triggered by non-user-initiated focuses, preventing a scenario where deleting one article accidentally marks the next one as read.

## 3. Sync and Upsert Defensive Mechanisms

Thanks to the current database schema, the `SyncService` has a natural defensive moat against resurrecting deleted entries:
- **Current State**: The `entry` table enforces unique constraints via the `idx_entry_feed_guid` and `idx_entry_feed_url` composite indexes. Furthermore, `SyncService` utilizes `try entry.insert($0, onConflict: .ignore)` during insertion.
- **Mechanism in Effect**: Once a record is marked with `isDeleted = 1`, the record still exists, and its `guid` and `url` retain their claims on the unique index. When subsequent syncs encounter the same feed XML, the conflict triggers the `.ignore` branch, effectively ignoring the insertion. The system will neither re-download the article nor falsely reset `isDeleted` to `false`, naturally avoiding duplicate pulls.
- **Future Consideration**: If the business logic is ever refactored to change `.ignore` to a true `.replace` or an `UPDATE`-based upsert, **guardrails must be added** to the update logic: only allow state updates if `isDeleted == false`.

## 4. Refactoring Data Flow and Query Construction

Currently, the `EntryStore.loadPage` method manages a massive, manually concatenated raw SQL string to accommodate various data source combinations (Feed, Tag, Unread, Search, etc.). As `isDeleted` filtering introduces another condition, the risk of string concatenation errors grows significantly.

**Refactoring Recommendations**:
1. **Centralized Rule Chain**: Treat entry visibility and selection as one shared filter chain, not as per-call-site SQL patches. The chain starts from "all entries", then applies ordered global rules (for example, `not deleted`), followed by user-scoped filters such as feed, unread, starred, search, and tag constraints.
2. **One Shared Builder for Entry Sets**: Introduce a common `EntryQuerySpec` / `EntryQueryBuilder`-style layer that builds the selected entry set exactly once. List loading, count queries, grouped counts, batch-selection reads, and query-scoped writes should all derive from this same builder instead of each one carrying its own visibility logic.
3. **Query Builder Is an Implementation Tool, Not the Goal**: GRDB query builder is still the preferred implementation style for complex list/query composition, but the important architectural goal is centralized entry-selection semantics. Small aggregate SQL queries may remain SQL if they consume the same shared selection contract instead of duplicating visibility logic.
4. **Benefits**: This keeps global entry-state rules such as `isDeleted` concentrated in one place, makes future global states easier to introduce, and avoids the current pattern where a new entry semantic has to be patched into many unrelated queries one by one.

Implementation note:
- This refactor should be completed as part of the current entry-delete work, not deferred.
- The feature itself does not logically depend on a full query/data-flow cleanup, but this is the right moment to consolidate the entry-list data flow and UI flow around one shared entry-selection builder so `isDeleted` filtering, selection handoff, and future list behavior all rest on one clearer implementation path.

## Part II. Current Codebase Status Confirmation

This section records the current implementation facts that matter for the feature, so the later plan stays grounded in actual repository behavior.

### 5. Data Model and Sync State

- `Entry` currently lives in `Mercury/Mercury/Core/Database/Models.swift` and does not yet have `isDeleted`.
- Feed sync inserts entries via `SyncService.syncParsedFeed` using `try entry.insert($0, onConflict: .ignore)`.
- The unique indexes `idx_entry_feed_guid` and `idx_entry_feed_url` already provide the anti-resurrection basis for a tombstone strategy.

### 6. User-Visible Entry Reads

- `EntryStore.loadPage` and `EntryStore.markRead(query:isRead:)` currently build raw SQL manually.
- `EntryStore.loadEntry` reads directly from `Entry.filter(Column("id") == id)`.
- `EntryStore.fetchRelatedEntries` performs a separate SQL query and must also be filtered.
- `SidebarCountStore.fetchProjection` counts unread/starred rows directly from `entry`.
- Tag batch estimation and selection queries in `AppModel+TagBatchExecution.swift` also read directly from `entry`.

Conclusion:
- Entry delete is not just a list query change. `isDeleted = 0` must be applied consistently across all user-visible and batch-selection read paths.
- In this iteration, the entry-list data flow and UI flow should be refactored together rather than patched piecemeal. The goal is not just to hide deleted rows, but to move entry-selection semantics into one shared builder so list loading, selection handoff, counts, and visibility filtering stay easier to reason about and maintain.

### 7. Selection and Auto Mark-Read

- `ContentView` already distinguishes system-driven versus user-driven selection through `autoSelectedEntryId`.
- `MarkReadPolicy.selectionOutcome(newId:autoSelectedId:)` already prevents auto mark-read when selection is system-driven.
- The existing starred handoff in `ContentView+EntryActions.swift` already contains the next/previous selection fallback pattern needed for delete.

Conclusion:
- We do not need a new read-state model for v1. Entry delete should reuse the existing system-driven selection contract.

### 8. Task and Runtime Topology

- Queue cancellation is task-ID based through `TaskCenter` / `AppModel.cancelTask(_:)`.
- Summary and translation waiting/active states are tracked in `AgentRuntimeEngine`.
- Panel tagging keeps an entry-to-task-ID map in `AppModel.activeTaggingPanelTaskIds`.
- Batch tagging does not currently expose a clean per-entry cancellation path while a run is active.

Conclusion:
- Entry delete needs one dedicated orchestration API in app/runtime code instead of view-local cancellation logic.
- Active batch-tagging participation should be treated as a deletion guard in v1.

## Part III. Implementation Details

### 9. Recommended v1 Product Scope

- Single-entry delete only.
- User-facing label remains `Delete`.
- No undo. This is a permanent destructive operation and should remain so.
- Initial UI surface should be the selected-entry action in the entry-list header menu.
- In the `...` menu, place `Delete Entry...` above `Mark Read`, separated as its own group by a divider.
- Row context menu and reader-toolbar action can be follow-up work after the storage/runtime contract stabilizes.

### 10. Data Contract

#### 10.1 Schema

Add a migration:

```sql
ALTER TABLE entry ADD COLUMN isDeleted BOOLEAN NOT NULL DEFAULT 0
```

Update the model:

```swift
struct Entry {
    ...
    var isDeleted: Bool = false
}
```

Implementation note:
- `FeedEntryMapper` and any other direct `Entry(...)` initializer call sites must be updated so new rows default to `false`.

#### 10.2 Cleanup Contract

Inside one transaction:

1. Delete entry-scoped derived rows from the tables listed in Part I.
2. Set `entry.isDeleted = 1`.

Do not delete:

- `llm_usage_event`
- run-scoped batch tables that cannot be safely edited per entry in v1

### 11. Visibility Contract

Once an entry is deleted, it must disappear from all user-visible surfaces.

This phase explicitly includes the planned refactor of the entry-list loading path onto a shared entry-selection builder. The current manually concatenated SQL in the main list flow should be replaced during this work, not after it.

Recommended shape:

```swift
struct EntryQuerySpec: Equatable {
    var feedId: Int64?
    var unreadOnly: Bool
    var starredOnly: Bool
    var searchText: String?
    var tagIds: Set<Int64>?
    var tagMatchMode: EntryStore.TagMatchMode
}
```

```swift
enum EntryQueryBuilder {
    static func buildVisibleEntries(spec: EntryQuerySpec) -> QueryInterfaceRequest<Entry> {
        // ordered global rules first, then user-scoped filters
    }
}
```

The important contract is:

- the builder owns global visibility rules such as `not deleted`
- callers provide only business filters through `EntryQuerySpec`
- list pages, counts, grouped counts, batch-selection reads, and query-scoped writes derive from the same selected-entry set
- adding future global entry states should primarily require changes in this shared builder layer rather than scattered call-site edits

Required filtering targets:

- `EntryStore.loadPage`
- the `keepEntryId` fetch inside `EntryStore.loadPage`
- `EntryStore.loadEntry`
- `EntryStore.fetchRelatedEntries`
- `EntryStore.markRead(query:isRead:)`
- `SidebarCountStore.fetchProjection`
- `AppModel.refreshCounts`
- tag batch selection and estimation queries

Recommended global rule:

```swift
Column("isDeleted") == false
```

Recommended behavior for entry-targeted writes:

- `markRead(entryId:isRead:)`
- `markStarred(entryId:isStarred:)`
- `updateURL(entryId:url:)`

These operations should no-op on deleted rows instead of mutating tombstones.

### 12. Delete Orchestration

Add a dedicated app-level API:

```swift
func deleteEntry(entryId: Int64) async throws
```

Recommended split:

- `Mercury/Mercury/Feed/UseCases/EntryDeleteUseCase.swift`
- `Mercury/Mercury/Feed/AppModel+EntryDelete.swift`

Suggested responsibilities:

- `EntryDeleteUseCase`
  - validate preconditions
  - check active batch-tagging guard
  - execute the database transaction
- `AppModel+EntryDelete`
  - cancel entry-scoped work before deletion
  - refresh counts and publish background mutation after success

### 13. Active Batch-Tagging Guard

Required behavior:
- reject deletion if the target entry participates in a `tag_batch_run` whose status is one of:
  - `running`
  - `ready_next`
  - `review`
  - `applying`

Rationale:
- Batch tagging already treats mutation of existing entry state during active lifecycle as forbidden.
- Entry deletion follows the same principle and should not introduce any exception path here.

Suggested query:

```sql
SELECT EXISTS (
  SELECT 1
  FROM tag_batch_entry tbe
  JOIN tag_batch_run tbr ON tbr.id = tbe.runId
  WHERE tbe.entryId = ?
    AND tbr.status IN ('running', 'ready_next', 'review', 'applying')
)
```

Suggested typed error:

```swift
enum EntryDeleteError: LocalizedError {
    case blockedByActiveTagBatch
}
```

### 14. Selection Handoff and Auto Mark-Read

When the deleted entry is currently selected:

1. select next entry if available
2. otherwise select previous entry
3. otherwise clear selection

Implementation detail:
- add a delete-specific helper in `ContentView+EntryActions.swift`, mirroring the existing starred fallback helper
- set `autoSelectedEntryId = fallbackEntryId`
- then set `selectedEntryId = fallbackEntryId`

This reuses the current system-driven selection path so delete handoff does not trigger delayed auto mark-read.

### 15. Error Surface

For explicit user-triggered delete actions:

- use the existing user-error surface via `appModel.reportUserError(title:message:)`

Recommended blocking copy for batch conflict:

- `This entry is part of an active batch tagging run. Finish or discard the batch before deleting it.`

## Part IV. Implementation Plan

### 16. Phase Breakdown

#### Phase 0. Regression Net First

- audit existing tests that already cover list/query/count/selection invariants
- add the missing baseline regression tests before touching `EntryStore.loadPage` and related visibility paths
- make sure the refactor has a stable safety net for:
  - entry-list query composition
  - selection handoff
  - sidebar counters
  - tag-batch selection visibility
  - deleted-row read suppression

#### Phase 1. Data Contract

- add `isDeleted` migration
- update `Entry`
- update direct `Entry(...)` initializer call sites
- keep new rows defaulting to `false`

#### Phase 2. Visibility Filtering

- introduce the shared `EntryQuerySpec` / `EntryQueryBuilder` layer for visible-entry selection
- move the entry-list loading path onto that shared builder
- migrate counts, related entries, query-scoped writes, and batch-estimation reads to consume the same selection semantics
- ensure `isDeleted = 0` is implemented as a centralized global rule in that builder instead of repeated per-call-site logic
- make targeted write paths no-op on deleted rows
- complete the planned entry-list data-flow and UI-flow refactor in the same implementation pass

#### Phase 3. Delete Backend

- add `EntryDeleteUseCase`
- add `AppModel.deleteEntry(entryId:)`
- implement active batch-tagging guard
- implement transaction cleanup + tombstone write

#### Phase 4. UI Wiring

- add `Delete Entry...` to `EntryListView` selected-entry menu
- place it above `Mark Read` and separate it with a divider as its own action group
- add confirmation state to `ContentView`
- add selection handoff helper
- report blocking and generic failures through existing surfaces

#### Phase 5. Verification

- run `./scripts/build`
- run targeted tests
- manually verify list/detail/sidebar behavior and selection handoff

## Part V. Test Plan

### Existing Coverage Snapshot

Existing tests already provide useful partial protection:

- `EntryStoreStarredTests`
  - covers `starredOnly` filtering
  - covers in-memory + database update behavior for `markStarred`
  - covers starred-only eviction
- `EntryLoadingRoutingTests`
  - covers `.all` / `.starred` / `.feed` query routing
- `StarredSelectionHandoffTests`
  - covers next/previous/clear handoff semantics
- `MarkReadPolicyTests`
  - covers system-driven selection versus auto mark-read behavior
- `SidebarCountStoreTests`
  - covers unread/starred/tag counter propagation
- `TagQueryTests`
  - covers tag `any` / `all` filtering
- `TagBatchSelectionFilteringTests`
  - covers batch-selection skip filters
- `SyncServiceStarredInvariantTests`
  - covers one important sync-preserved local-state invariant

Current gaps relative to entry delete and list-flow refactor:

- no coverage for deleted-row suppression in list reads
- no coverage for `EntryStore.loadEntry` visibility after deletion
- no coverage for `EntryStore.fetchRelatedEntries` visibility after deletion
- no direct baseline coverage for list search behavior (`title` / `summary`)
- no direct baseline coverage for unread `keepEntryId` injection behavior
- no direct baseline coverage for list pagination/cursor behavior after predicate changes
- no coverage for sidebar counts excluding tombstoned rows
- no coverage for tag-batch estimation excluding tombstoned rows
- no delete-specific selection handoff tests
- no delete-orchestration tests for cancellation / blocking behavior

### 17. Migration and Persistence

Add tests for:

- migration adds `isDeleted` with default `false`
- tombstoned rows remain in `entry`
- derived tables are cleaned
- `llm_usage_event` rows are retained

### 18. Visibility

Add tests for:

- `EntryStore.loadPage` excludes deleted rows
- `EntryStore.loadEntry` returns `nil` for deleted rows
- `EntryStore.fetchRelatedEntries` excludes deleted rows
- sidebar unread/starred counts exclude deleted rows
- tag batch estimation excludes deleted rows

Also add baseline regression tests that protect existing list behavior during the refactor:

- search continues to match `Entry.title` and `Entry.summary` only
- unread `keepEntryId` injection still works only on the intended path
- pagination cursor ordering remains stable when filtering is applied
- feed/unread/starred/tag/search combinations still compose correctly

### 19. Selection and Runtime

Add tests for:

- deleting selected entry hands off to next row
- fallback uses previous row when next is unavailable
- deleting the only visible row clears selection
- system-driven handoff does not trigger auto mark-read
- queued summary/translation work for the entry is abandoned
- active panel-tagging work is cancelled
- delete is blocked for entries that participate in an active batch-tagging lifecycle

### 20. Sync Integrity

Add tests for:

- repeated sync of the same feed item does not recreate a tombstoned entry

## Part VI. Remaining Gaps Before Implementation

### 21. Remaining Gaps

At this point, the major product decisions are settled:

- no undo
- active batch-tagging lifecycle blocks deletion
- `Delete Entry...` lives in the entry-list `...` menu above `Mark Read`, separated into its own group
- the entry-list data-flow and UI-flow refactor should be completed in this work

The remaining gaps are implementation-level only:

1. Finalize the refactor boundary for the entry list.
   - The preferred implementation path is to complete the shared `EntryQuerySpec` / builder extraction in this iteration and move the entry-list loading path onto it.
   - If implementation uncovers a strong constraint that requires a narrower refactor boundary, that deviation should be documented explicitly and still preserve one centralized entry-selection flow rather than adding more ad-hoc SQL branching.

2. Verify all entry-visible count/query surfaces are covered in one pass.
   - The known set is documented, but implementation should explicitly audit for any additional `entry` reads that should derive from the shared builder and could otherwise leak deleted rows into UI or batch selection.

3. Define the concrete cancellation helper API in app/runtime code.
   - The behavioral requirement is clear, but the exact helper shape should be finalized when wiring `AppModel.deleteEntry(entryId:)`.
