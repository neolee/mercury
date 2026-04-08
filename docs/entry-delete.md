# Entry Delete Feature Design and Implementation Guide

To address issues such as duplicated feed items or inappropriate content, Mercury introduces a single-entry "delete" feature. To balance RSS sync semantics with local storage reclamation, we are adopting a hybrid strategy: a **tombstone mechanism (soft delete) combined with hard deletion of associated data**.

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

## 2. Cancellation Timing and Cleanup Sequence (Best Practice)

To prevent UI crashes, "zombie" state updates, and data races, the deletion operation must strictly follow this execution order:

1. **UI Focus Reset and Transfer**
   - **Routing logic**: Align with the "mark read/unread" behavior. When the deleted `Entry` is the currently selected article in the reader, the system should first attempt to select the **next entry**. If there is no next entry, fall back to the **previous entry**. If it is the only item in the list, set `selectedEntryId` to `nil`.
2. **Abort Agents and Background Tasks**
   - Immediately after navigating away from the target `Entry`'s UI focus, invoke `TaskCenter` and `AgentRuntimeEngine` to cancel all active tasks bound to this `entryId` (including summaries, translations, and tag operations, whether running or queued). This completely severs network requests and state callbacks associated with this record.
3. **Database Transaction**
   - After the first two steps (UI detachment, task abortion) are complete, open a GRDB `db.write` or `db.inTransaction` scope.
   - Safely execute the `DELETE` operations for the 9 tables listed above, and finally execute `UPDATE entry SET isDeleted = 1 WHERE id = ?` within this single transaction.

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
1. **Transition to GRDB Query Builder**: Replace hardcoded SQL patterns with strongly typed builder patterns. For example, using a base query chain like `Entry.including(required: Entry.feed).filter(Column("isDeleted") == false)`.
2. **Reusable Composability**: Treat all Feed ID, Unread, Search, and Tag filters as subsequent, optional `.filter(...)` modifiers attached to the base request.
3. **Benefits**: This eradicates the risk of string concatenation vulnerabilities and drastically improves the readability of the several-hundred-line `loadPage` implementation. Furthermore, it ensures that `isDeleted` entries are globally and consistently filtered out regardless of the entry point (e.g., standard list, search results, or tag view).
