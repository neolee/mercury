# Tags v2 Batch Tagging Design Memo

> Date: 2026-03-05
> Status: Draft for discussion (not yet finalized)
> Scope: Batch tagging subsystem only (UI + orchestration + staging persistence)

This document is intentionally separate from `tags-v2.md` and `tags-v2-tech-contracts.md`.
It captures current discussion outcomes and open decisions for the batch tagging subsystem.

---

## 1. Decision Snapshot (Current Discussion)

### 1.1 Confirmed decisions
- Matched tags and new proposals both go through staging first.
- User review granularity is only at **new tag proposal** level (not per-entry manual review).
- In-run LLM request concurrency is user-configurable, default `3`, range `1...5`.
- Final apply uses chunked idempotent commits.
- Scope is selected by time/read dimensions, with dynamic target-count preview.
- Large target sets are handled by **warning + explicit user confirmation**, not silent truncation.
- Batch processing state is stored in dedicated batch tables, never in `entry` table columns.

### 1.2 Design principle
- Reuse existing `TaskQueue` + `TaskCenter` + `AgentRuntime` infrastructure as much as possible.
- Do not introduce a separate global scheduler for batch tagging.

---

## 2. Scope Selection Strategy

## 2.1 Recommendation
User first chooses scope by time/read intent:
- `Past Week`
- `Past Month`
- `Past Three Months`
- `Past Six Months`
- `Past Twelve Months`
- `All Unread`
- `All Entries`

The panel dynamically computes and shows the candidate entry count before execution.

## 2.2 Should we always limit batch size?
Execution should not silently truncate by a product-level hard cap.
Instead, use a soft warning threshold and let users decide whether to continue.

Reasons:
- Maintains user control for local-model users who can process very large sets cheaply.
- Still provides strong cost/risk signaling for paid API users.
- Avoids hidden behavior where user-selected scope differs from actual processed set.

## 2.3 Threshold and safeguards
- Add `BatchTaggingPolicy.warningThreshold = 100` (initial value).
- If target count exceeds threshold, show a blocking confirmation:
  - warning about token/time cost,
  - warning about potential paid-provider billing impact,
  - explicit `Continue` / `Cancel` action.
- Keep a high internal `absoluteSafetyCap` only as a technical safeguard against accidental runaway workloads.
  - This is an engineering protection layer, not normal product behavior.

Potential future extension (not required now): provider-specific guidance in the warning message (for local vs remote routes).

---

## 3. Batch Panel UX (Single Independent Sheet)

The panel is opened from `Settings > General > Tag System > Batch Tagging...`.

State machine:
`Configure -> Running -> Review -> Applying -> Done`

## 3.1 Configure
Fields:
- Scope picker (7 options listed above).
- `Skip articles already batch-tagged` checkbox (default checked).
- `Concurrency` slider/stepper (`1...5`, default `3`).

Preview card:
- matched entry count,
- expected processing count,
- estimated runtime range,
- warning banner when `count > warningThreshold`.

Actions:
- `Start Batch Tagging` (explicit second intent),
- `Cancel`.

## 3.2 Running
Display:
- progress (`processed / total`),
- success/failure item counters,
- current phase text (`Requesting`, `Parsing`, `Staging`),
- optional ETA.

Actions:
- `Cancel run`: Halts further LLM processing. The run then automatically transitions to the `Review` phase for entries already processed successfully up to that point. This approach handles "pause/resume" user needs dynamically without a dedicated paused state.

Notes:
- No modal error interruption for per-item failures.
- Failures are accumulated in run stats and debug diagnostics.

Skip semantics:
- `Skip articles already batch-tagged` currently means skipping entries that reached batch `applied` state.
- Entries in `failed` / `cancelled` states are not skipped, so users can retry naturally.

## 3.3 Review
Purpose: review only **new tag proposals**.

Display:
- grouped by normalized proposal name,
- each row shows proposal name + hit count + sample entries count.

Actions:
- row-level `Keep` / `Discard`,
- bulk actions (`Keep All`, `Discard All`),
- `Apply Decisions`,
- `Cancel / Discard Run`: Ends the batch completely. Requires a strong warning confirmation, as this will discard all processed results and abort the task.

Matched existing tags are not reviewed one-by-one.

## 3.4 Applying
Display:
- chunked apply progress (`chunk x/y`),
- inserted/ignored counters.

Behavior:
- idempotent chunk commits,
- partial progress persisted for resume,
- cancel stops future chunks (already applied chunks remain committed).

## 3.5 Done
Summary:
- total selected / processed entries,
- failed item count,
- kept/discarded proposal counts,
- final inserted `entry_tag` row count,
- created new `tag` row count,
- total elapsed time.

---

## 4. Window Lifecycle and Interaction Rules

## 4.1 Can users close the task sheet and Settings window?
No. While a batch is in progress (`Running`, `Review`, `Applying`), the Settings window and Batch Tagging sheet cannot be closed (to preserve task context explicitly).
However, users can switch focus back to the main app window and continue reading.

## 4.2 Settings lock policy during batch lifecycle
When stage is `Running`, `Review`, or `Applying`:
- disable unrelated settings controls (prevent configuration drift),
- keep only batch panel entry and run status interactive.

Rationale:
- avoid mid-run mutation of model routes/prompt settings that can invalidate run assumptions.

## 4.3 Conflict control with normal app actions
Allowed while batch is active:
- reading entries,
- manual single-entry tagging,
- feed sync,
- marking articles as read,
- deleting entries (during final `apply`, the missing entry is simply ignored via `INSERT OR IGNORE`).

Restricted while batch is active:
- destructive operations on the main window that can invalidate review semantics (`merge`, `rename`, `delete` tag) are disabled.

Safety rule at apply time:
- re-resolve normalized names against latest `tag` + `tag_alias` before final write,
- insert with idempotent semantics (`INSERT OR IGNORE`),
- recompute usage/provisional state from persisted truth after apply.

---

## 5. Orchestration: Reuse Existing Task Infrastructure

## 5.1 Execution model
- Enqueue one outer task with `AppTaskKind.taggingBatch`.
- Outer task owns lifecycle and progress reporting.
- Inner per-entry LLM calls run inside outer task with bounded parallelism (`1...5`).
- Inner calls do not become separate `AppTask` records.

## 5.2 Runtime integration
- Keep using existing route resolution and provider invocation stack.
- Keep existing failure classification and timeout policy patterns.
- Keep `FailurePolicy.shouldSurfaceFailureToUser(kind: .taggingBatch) == false`.

## 5.3 Rate Limits (429) & Error Handling
- Bounded concurrency (`1...5`) helps prevent initial rate limit hits.
- The LLM Executor must include explicit handling for HTTP 429 (Too Many Requests) utilizing exponential backoff.
- If retries exhaust for a given entry, the item is marked as `failed`, logged, and the system moves to the next entry. **Do not fail or abort** the entire batch run due to per-item rate limits or timeouts.

---

## 6. Shared Single-Entry LLM Execution Abstraction

To avoid duplicated logic between panel tagging and batch tagging, extract a reusable executor with configurable profile.

## 6.1 Proposed profile object
```swift
struct TaggingLLMRequestProfile: Sendable {
    let templateID: String
    let templateVersion: String
    let maxTagCount: Int
    let maxNewTagCount: Int
    let bodyStrategy: TaggingBodyStrategy
    let timeoutSeconds: TimeInterval
    let temperatureOverride: Double?
    let topPOverride: Double?
}

enum TaggingBodyStrategy: Sendable {
    case readabilityPrefix(Int)   // panel example: first 800 chars
    case summaryOnly              // batch example
}
```

## 6.2 Proposed reusable output contract
```swift
struct TaggingPerEntryResult: Sendable {
    let entryId: Int64
    let rawResponse: String
    let parsedNames: [String]
    let normalizedNames: [String]
    let resolvedExistingTagIDs: [Int64]
    let newProposals: [String]
    let providerProfileId: Int64?
    let modelProfileId: Int64?
    let promptTokens: Int?
    let completionTokens: Int?
    let durationMs: Int
    let errorMessage: String?
}
```

Panel and batch differ only by `TaggingLLMRequestProfile` and post-processing destination. 

**Critical Requirement:** Both single-entry and batch tagging tasks **must** persist resource usage data correctly, using the existing `.tagging` and `.taggingBatch` variants to map tokens directly to the central `LLMUsageEventPersistence` tracking, exactly identically to `summary` and `translation` tasks.

---

## 7. Persistence Model (Staging-First)

All intermediate and per-entry outputs are persisted to staging tables.
No writes to `tag`/`entry_tag` occur before review/apply.
Batch processing status for entries must be managed in dedicated batch tables, not in `entry` table columns.

## 7.1 Proposed tables
- `tag_batch_run`
  - run metadata and state (`configure`, `running`, `review`, `applying`, `done`, `cancelled`, `failed`)
  - scope, selected options, counters, timestamps
- `tag_batch_entry`
  - Combinied per-entry processing status and lifecycle state tracking (replacing originally separate `item` and `entry_state` schemas).
  - lifecycle states: `never_started`, `running`, `failed`, `staged_ready`, `applied`
  - includes: attempts, raw response, error messages
  - linked via `entryId + runId` for context and traceability
- `tag_batch_assignment_staging`
  - staged candidate assignments by entry + normalized tag
  - includes optional resolved existing `tagId`
- `tag_batch_new_tag_review`
  - aggregated proposal rows and user decision (`pending`, `keep`, `discard`)
- `tag_batch_apply_checkpoint`
  - chunk apply checkpoint for resume

## 7.2 Apply contract
Apply starts only after review decisions are complete.

Per chunk:
1. Resolve/refresh canonical tag IDs for staged normalized names.
2. Create new tags for `keep` proposals (initially `isProvisional = true`) if not existing.
3. Insert into `entry_tag` idempotently.
4. Persist chunk checkpoint.

After all chunks:
- recompute affected tags' `usageCount`,
- recompute provisional promotion state by policy,
- mark run `done`.

## 7.3 Data Cleanup Strategy
To prevent database bloat, the system should implement lifecycle cleanup for staging rows explicitly tied to a batch run:
- **Upon Success/Completion:** When a run reaches `done`, remove the weighty per-entry staging texts/responses from `tag_batch_entry`, `tag_batch_assignment_staging`, and `tag_batch_new_tag_review` for that specific run context.
- **Upon Cancel/Discard Run:** If the run is decisively aborted during `Review` (or fully canceled while `Running` via the discard variant), similarly drop all of its staged rows to free up space.
- Usage tracking metadata and minimal `tag_batch_run` stats logs (total processed, final counts, times) may be retained structurally, possibly with a rolling limit (e.g., retain the last 5 or 10 runs).

---

## 8. Resume and Recovery

On app launch or panel open:
- if latest run state is `running` or `applying`, resume automatically.
- if state is `review`, reopen directly at review stage.
- resume always reads staging + checkpoint, never rebuilds from volatile memory.
- status restoration for each entry comes from `tag_batch_entry`, respecting state continuity globally.

---

## 9. Open Questions / Status

- **Pause/Resume:** Explicit pause deferred in v1. `Cancel run` during the `Running` phase will function dynamically as early partial-review transitioning, allowing the user to review what's done so far. `Cancel / Discard` inside `Review` will act as a total destruction of the run.
- **warningThreshold:** Set structurally at `100` for initial iterations. User flexibility configuration pushes to later milestones.
- **Conflict control restrictions:** Limited primarily to locking the settings/task sheet and strictly barring `rename`, `delete`, and `merge` actions on main UI tag lists. Feed deletion and read lifecycle are permitted and inherently resolved properly.

---

## 10. Implementation Guidance (Document-only, no code yet)

This section defines an execution-ready rollout plan aligned with the decisions in Sections `3.x`, `4.x`, `5.3`, `6.2`, and `7.x`.

## 10.1 Phase A - Runtime Policy and State Contracts

Goal:
- freeze and enforce batch lifecycle semantics before feature coding.

Scope:
- confirm `Configure -> Running -> Review -> Applying -> Done` transition matrix,
- enforce dual cancel semantics:
  - `Running + Cancel run` => stop future per-entry work, transition to `Review` with partial staged outputs,
  - `Review + Cancel/Discard Run` => destructive discard with explicit confirmation,
- ensure `taggingBatch` has `active=1`, `waiting=0` semantics.

Primary files:
- `Mercury/Mercury/Agent/Runtime/AgentRunCore.swift`
- `Mercury/Mercury/Core/Tasking/TaskLifecycleCore.swift`
- `Mercury/Mercury/Core/Tasking/FailurePolicy.swift`
- `Mercury/Mercury/App/AppModel.swift`

Acceptance:
- no waiting queue for `.taggingBatch`,
- runtime policy matches this memo and `tags-v2-tech-contracts.md`,
- no user-facing alert surface introduced for batch per-item failures.

## 10.2 Phase B - Persistence Schema and Repositories

Goal:
- establish complete staging-first persistence for batch runs.

Scope:
- add migrations and models for:
  - `tag_batch_run`,
  - `tag_batch_entry`,
  - `tag_batch_assignment_staging`,
  - `tag_batch_new_tag_review`,
  - `tag_batch_apply_checkpoint`,
- add repository APIs for:
  - run creation/loading,
  - per-entry staging upsert,
  - review decision writes,
  - apply checkpoint read/write,
  - run-final cleanup.

Primary files:
- `Mercury/Mercury/Core/Database/DatabaseManager+Migrations.swift`
- `Mercury/Mercury/Core/Database/Models.swift`
- new `Mercury/Mercury/Core/Database/Models+TagBatch.swift`
- new `Mercury/Mercury/Core/Database/TagBatchStore.swift`

Acceptance:
- app can migrate from old schema to new schema without manual steps,
- staging rows can fully reconstruct run state after restart,
- no pre-review write to `tag` / `entry_tag` from batch new proposals.

## 10.3 Phase C - Shared Per-Entry Executor Extraction

Goal:
- avoid duplicated panel vs batch LLM logic and guarantee identical token accounting.

Scope:
- introduce reusable per-entry tagging executor with profile input:
  - `TaggingLLMRequestProfile`,
  - `TaggingBodyStrategy`,
  - `TaggingPerEntryResult` with `promptTokens` and `completionTokens`,
- have panel and batch both call this executor,
- record usage via existing usage persistence path (`LLMUsageEventPersistence` contract) with `.tagging` / `.taggingBatch` semantics.

Primary files:
- `Mercury/Mercury/Agent/Tagging/AppModel+TagExecution.swift`
- new shared executor file under `Mercury/Mercury/Agent/Tagging/`
- `Mercury/Mercury/Agent/Shared/AgentExecutionShared+Persistence.swift`

Acceptance:
- panel behavior remains unchanged functionally,
- batch can consume the same normalized output contract,
- per-entry token usage fields are persisted and queryable.

## 10.4 Phase D - Batch Orchestration and 429 Degradation

Goal:
- implement one outer batch task with resilient per-item continuation.

Scope:
- add outer task execution for `AppTaskKind.taggingBatch`,
- process entries with bounded internal concurrency (`1...5`, default `3`),
- implement explicit 429 retry with exponential backoff,
- on retry exhaustion for one entry: mark item `failed`, continue next entries,
- support partial completion transition to `Review` on running cancel.

Primary files:
- new `Mercury/Mercury/Agent/Tagging/AppModel+TagBatchExecution.swift`
- `Mercury/Mercury/Core/Tags/BatchTaggingPolicy.swift`

Acceptance:
- one entry timeout/429 failure never aborts the whole run,
- run statistics reflect success/failed counts accurately,
- checkpoint resume works after force quit.

## 10.5 Phase E - Review, Apply, and Data Cleanup

Goal:
- finalize user decisions safely and keep storage bounded.

Scope:
- implement review list and decision actions (`keep` / `discard`, row + bulk),
- apply by chunks with idempotent inserts (`INSERT OR IGNORE`) and checkpoint persistence,
- re-resolve normalized names against latest `tag`/`tag_alias` before each apply chunk,
- run finalization:
  - success (`done`) retains minimal run stats,
  - discard clears all heavy staging rows,
  - optional rolling retention for old `tag_batch_run` summaries.

Primary files:
- batch execution/store layer files from Phases B/D

Acceptance:
- apply is resumable and idempotent,
- discard path is destructive only after explicit confirmation,
- storage growth from long text staging remains controlled.

## 10.6 Phase F - Settings/Sheet UX and Conflict Boundaries

Goal:
- enforce window lifecycle and app-action boundaries defined in Section 4.

Scope:
- wire `Settings > General > Tag System > Batch Tagging...` to real sheet flow,
- enforce non-closeable sheet/settings behavior during `Running` / `Review` / `Applying`,
- allow focus switch back to main window,
- disable only destructive tag operations (`rename`, `delete`, `merge`) while batch is active.

Primary files:
- `Mercury/Mercury/App/Views/AppSettingsView.swift`
- new `Mercury/Mercury/App/Views/BatchTaggingSheetView.swift`
- new `Mercury/Mercury/App/Views/BatchTaggingSheetViewModel.swift`
- tag operation command wiring files (where rename/delete/merge are triggered)

Acceptance:
- UX behavior matches Section `4.1`/`4.3` exactly,
- normal feed operations remain available during batch lifecycle.

## 10.7 Phase G - Test Matrix and Verification

Goal:
- guarantee lifecycle correctness, idempotence, and regression safety.

Scope:
- add tests for:
  - state transitions and dual-cancel semantics,
  - per-item 429 retry/degrade behavior,
  - apply idempotence and checkpoint resume,
  - conflict controls for destructive tag actions,
  - cleanup strategy on `done` and `discard`.

Suggested test files:
- `Mercury/MercuryTest/TagBatchStateMachineTests.swift`
- `Mercury/MercuryTest/TagBatchExecutionTests.swift`
- `Mercury/MercuryTest/TagBatchApplyIdempotencyTests.swift`
- `Mercury/MercuryTest/TagBatchCleanupTests.swift`

Final verification:
- run `./scripts/build` from repo root,
- ensure no compiler warnings/errors are introduced,
- manually validate end-to-end flow: Configure -> Running -> Review -> Applying -> Done and both cancel paths.

## 10.8 File-Level Change Map (Confirmed)

This map is the implementation checklist for file-level work. It reflects explicit decisions confirmed in review.

### 10.8.1 New files to add (confirmed)

1. `Mercury/Mercury/Agent/Tagging/AppModel+TagBatchExecution.swift`
  - Owns outer batch task lifecycle (`Configure/Running/Review/Applying/Done`), bounded per-entry concurrency, cancel transitions, and checkpoint-driven resume.
2. `Mercury/Mercury/Agent/Tagging/TaggingLLMExecutor.swift`
  - Shared per-entry executor for both panel and batch paths, including parse/normalize/resolve/token accounting output contract.
3. `Mercury/Mercury/Core/Database/TagBatchStore.swift`
  - Dedicated staging repository for `tag_batch_*` read/write APIs and cleanup operations.
4. `Mercury/Mercury/Core/Database/Models+TagBatch.swift`
  - Batch table model definitions separated from core `Models.swift` to keep model surfaces maintainable.
5. `Mercury/Mercury/App/Views/BatchTaggingSheetView.swift`
  - Batch tagging sheet UI and stage rendering.
6. `Mercury/Mercury/App/Views/BatchTaggingSheetViewModel.swift`
  - Sheet state orchestration and action dispatch; keeps `View` declarative and test-friendly.

### 10.8.2 Existing files to modify (confirmed)

1. `Mercury/Mercury/Agent/Runtime/AgentRunCore.swift`
  - Enforce `waiting=0` semantics correctly for `.taggingBatch`.
2. `Mercury/Mercury/App/AppModel.swift`
  - Correct runtime policy wiring from `.tagging: 2` to agreed values and include `.taggingBatch` explicitly.
3. `Mercury/Mercury/Core/Database/DatabaseManager+Migrations.swift`
  - Add migrations for `tag_batch_run`, `tag_batch_entry`, `tag_batch_assignment_staging`, `tag_batch_new_tag_review`, `tag_batch_apply_checkpoint`.
4. `Mercury/Mercury/Core/Database/Models.swift`
  - Add/adjust shared enums and references needed by batch models and task state projection.
5. `Mercury/Mercury/Agent/Tagging/AppModel+TagExecution.swift`
  - Refactor panel path to consume the shared `TaggingLLMExecutor`.
6. `Mercury/Mercury/Core/Tags/BatchTaggingPolicy.swift`
  - Add finalized batch constants (`warningThreshold`, retry/backoff knobs, and bounded concurrency policy values).
7. `Mercury/Mercury/App/Views/AppSettingsView.swift`
  - Wire real `Batch Tagging...` sheet entry and lifecycle locks.
8. `Mercury/Mercury/App/Views/ContentView.swift`
  - Disable destructive tag operations (`rename/delete/merge`) while batch is in active lifecycle stages.
9. `Mercury/Mercury/Feed/Views/SidebarView.swift`
  - Reflect destructive action disablement in sidebar tag menus.
10. `Mercury/Mercury/Core/Database/EntryStore.swift`
  - Add defensive mutation guards for destructive tag ops during active batch runs.
11. `Mercury/Mercury/Agent/Shared/AgentExecutionShared+Persistence.swift`
  - Ensure usage persistence linkage remains consistent for `.tagging` and `.taggingBatch` execution paths.

### 10.8.3 Priority fixes before full feature coding

These two fixes are mandatory and must land first:

1. Runtime waiting semantics fix:
  - `AgentRunCore.waitingLimit(for:)` must permit configured `0` (no implicit `max(1, ...)` for waiting slots).
2. `AppModel` runtime policy fix:
  - remove the current `.tagging: 2` deviation and align with confirmed policy for panel + batch behavior.
