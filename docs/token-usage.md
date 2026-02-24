# Token Usage Tracking
    
*Decision Draft*

## Overview

This document defines the next implementation baseline for Token Usage Tracking in Mercury.

Primary goal:
- Persist complete and real token traffic for every LLM request event.

Non-goal for v1:
- No currency/cost estimation. Users can estimate money externally.

This scope intentionally separates **data truth** from **presentation**:
- Data layer records everything that actually happened.
- Query/UI layer decides filtering, grouping, and report views.

---

## Core Decisions

1. **Fact granularity is per LLM request**, not per task run.
2. **Do not pre-filter at write time** (`succeeded`, `failed`, `cancelled` are all recorded).
3. **Usage storage is independent from `AgentTaskRun` semantics**, with optional foreign-key linkage.
4. **Provider/Model lifecycle uses soft-delete (archive), not hard delete**.
5. **No currency fields in v1**.

---

## Pre-Task (Required): Provider/Model Lifecycle Refactor

This refactor is a prerequisite and should be implemented and validated before token usage feature work.

### Data model changes

#### `agent_provider_profile`
- Keep existing `isEnabled`.
- Add `isArchived` (`BOOLEAN NOT NULL DEFAULT 0`).
- Add `archivedAt` (`DATETIME NULL`).

#### `agent_model_profile`
- Keep existing `isEnabled`.
- Add `isArchived` (`BOOLEAN NOT NULL DEFAULT 0`).
- Add `archivedAt` (`DATETIME NULL`).

### Behavior rules

1. **Archive provider**
     - No physical delete.
     - Set `isArchived = 1`, `archivedAt = now`.
     - Cascade archive to its models (`isArchived = 1`).
     - Delete confirmation must explicitly list impacted models, e.g.:
       - `Delete provider "X"?`
       - `Related models will be archived: A / B / C.`

2. **Archive model**
     - No physical delete.
     - Set `isArchived = 1`, `archivedAt = now`.

3. **Create provider (reactivation-first)**
     - Normalize `baseURL` first.
     - If an archived provider with the same normalized `baseURL` exists, reuse the row (update fields, clear archive flags).
     - Otherwise create a new row.

4. **Create model (reactivation-first)**
     - Match archived model by `(providerProfileId, modelName)`.
     - If matched, reuse row and clear archive flags.
     - Otherwise create a new row.

5. **Default query behavior**
     - Runtime candidate selection must exclude archived rows.
     - Settings lists only show active rows (archived rows are not shown in picker/list UI).

### Why this is required first

- Reduces migration risk for usage analytics by stabilizing provider/model identity over time.
- Keeps historical references meaningful when entities are removed from active config.
- Avoids data fragmentation caused by delete/recreate cycles.

---

## Token Usage Data Model

Introduce a new fact table: `llm_usage_event`.

### Table definition (logical)

- `id` (PK)
- `taskRunId` (nullable FK -> `agent_task_run.id`)
- `entryId` (nullable FK -> `entry.id`)
- `taskType` (`summary` / `translation` / future)

- `providerProfileId` (nullable FK)
- `modelProfileId` (nullable FK)

- `providerBaseURLSnapshot` (TEXT, not null)
- `providerNameSnapshot` (TEXT, nullable)
- `modelNameSnapshot` (TEXT, not null)

- `requestPhase` (TEXT, not null)
    - initial values: `normal`, `repair`, `retry`.

- `requestStatus` (TEXT, not null)
    - initial values: `succeeded`, `failed`, `cancelled`, `timedOut`.

- `promptTokens` (INTEGER, nullable)
- `completionTokens` (INTEGER, nullable)
- `totalTokens` (INTEGER, nullable)

- `usageAvailability` (TEXT, not null)
    - initial values: `actual`, `missing`.

- `startedAt` (DATETIME, nullable)
- `finishedAt` (DATETIME, nullable)
- `createdAt` (DATETIME, not null)

### Indexes (initial)

- `(createdAt)`
- `(taskType, createdAt)`
- `(providerProfileId, createdAt)`
- `(modelProfileId, createdAt)`
- `(requestStatus, createdAt)`
- `(taskRunId)`

### Retention

Add app setting for usage retention window:
- `1 month`, `3 months`, `6 months`, `12 months`, `Forever`.

Retention cleanup can run:
- On app launch (best-effort, only after startup migration gate is completed).

---

## Runtime Instrumentation Rules

### Summary

Each provider call emits one usage event.

If route fallback happens (candidate 1 fails, candidate 2 succeeds):
- Write one failed/cancelled event for candidate 1 (if request started).
- Write one success event for candidate 2.

### Translation

Translation can issue multiple LLM calls in one run:
- Strategy A: one call.
- Strategy C: per-chunk calls.
- Repair path: additional repair call.

**Each call must emit one usage event** with correct `requestPhase`.

### Missing usage tokens

When provider returns no usage payload:
- Keep token columns `NULL`.
- Set `usageAvailability = missing`.

Do not synthesize token values in v1.

---

## Reporting & Entry Points

Usage is strongly related to task/provider/model. We support multiple entry points using shared query APIs.

### Reporting scope (explicit)

- Settings pickers/lists remain **active-only** (archived objects are hidden).
- Usage reports remain **history-complete by default**, including events linked to archived provider/model identities.
- If a usage row references an archived entity, report rendering should still show it (for example with an `Archived` badge in labels).
- This rule is mandatory to avoid historical traffic loss in trend and comparison charts.

### Shared query service

Define a usage query module with filter-based APIs:
- Time range
- Task type
- Provider
- Model
- Status set

### Entry points

1. Provider selected -> right pane `Statistics` button (provider-pre-filtered).
2. Model selected -> right pane `Statistics` button (model-pre-filtered).
3. Task selected (Summary/Translation) -> right pane `Statistics` button (task-pre-filtered).
4. List toolbar -> add `Statistics` icon button for current dimension comparison:
     - Providers section: provider usage comparison view.
     - Models section: model usage comparison view.
     - Agents section: task usage comparison view.

All entry points should open the same report shell with pre-applied filter context.

---

## UI Scope (v1)

### Included

- Time range switch: Today / 7d / 30d / Custom.
- Overview cards: total/prompt/completion.
- Daily stacked bar (Summary vs Translation).
- Top models list.
- Top providers list.
- Status legend (include failure/cancelled traffic).
- Contextual statistics trigger buttons inside existing settings panes (no dedicated Usage tab).
- Default status scope includes all likely billable traffic (`succeeded`, `failed`, `cancelled`, `timedOut`).

### Deferred

- Money/currency views.
- Deep drill-down pivot builder.
- Reader inline per-run token badge.

---

## Detailed Implementation Plan

## Phase 0 — Pre-migration design lock

1. Freeze provider/model archive semantics.
2. Freeze URL normalization rules for provider matching.
3. Freeze usage event status and phase enum values.

Deliverable:
- Approved schema and behavior checklist.

## Phase 0.5 — Startup migration gate (required for 1.x upgrades)

Because 1.* is already released, database schema upgrade must be treated as an explicit startup gate.

Requirements:
1. App startup enters a dedicated migration phase before any automatic startup jobs.
2. During this phase, run all pending DB migrations and block:
     - feed auto sync,
     - background task restore/replay,
     - usage retention cleanup,
     - any other startup automation touching DB data.
3. Continue startup automation only after migration is confirmed successful.
4. If migration fails, app must surface a clear blocking error and skip all automatic jobs.

Verification:
- Upgrade path from existing 1.x data succeeds without startup race conditions.
- No startup auto operation runs before migration completion.
- Data integrity is preserved after migration.

## Phase 1 — Provider/Model archive refactor (prerequisite)

1. Add `isArchived` + `archivedAt` to provider/model tables.
2. Update app models and read/write paths.
3. Replace hard delete in settings with archive operations.
4. Update provider delete confirmation copy to include impacted model names.
5. Implement provider/model reactivation-on-create.
6. Ensure runtime route selection excludes archived entities.

Verification:
- Existing config UI still works.
- Archive -> recreate -> row reuse works.
- Provider delete confirmation accurately lists impacted models.
- Default selection and routing remain stable.

## Phase 0.5-1 — Development Task Checklist (ready to implement)

This checklist breaks Phase 0.5 and Phase 1 into concrete engineering tasks.

### A. Startup migration gate

1. Add an explicit startup state machine step: `migratingDatabase`.
2. Ensure DB migration completion is awaited before triggering startup automations.
3. Block startup jobs until migration succeeds:
     - feed auto sync,
     - background restoration/replay,
     - retention cleanup.
4. Add migration failure surface:
     - blocking status in UI,
     - no auto-jobs dispatched when migration fails.

### B. Schema migration for archive lifecycle

1. Add migration for `agent_provider_profile`:
     - `isArchived BOOLEAN NOT NULL DEFAULT 0`,
     - `archivedAt DATETIME NULL`.
2. Add migration for `agent_model_profile`:
     - `isArchived BOOLEAN NOT NULL DEFAULT 0`,
     - `archivedAt DATETIME NULL`.
3. Backfill safety checks:
     - existing rows default to active (`isArchived = 0`).

### C. Model and query updates

1. Extend `AgentProviderProfile` and `AgentModelProfile` structs with new fields.
2. Update all active-runtime queries to include `isArchived = false`.
3. Keep analytics/report queries archive-inclusive by default (no `isArchived` exclusion).

### D. Archive operations (replace hard delete)

1. Replace provider delete action with archive action.
2. Implement provider archive cascade to all models under that provider.
3. Replace model delete action with archive action.
4. Keep existing default-provider/default-model invariants intact after archive.

### E. Reactivation-on-create

1. Implement base URL normalization helper for provider identity matching.
2. On provider save:
     - try exact match on normalized `baseURL` among archived rows,
     - if matched: update row + clear archive flags,
     - else: insert new row.
3. On model save:
     - match archived row by `(providerProfileId, modelName)`,
     - if matched: update row + clear archive flags,
     - else: insert new row.

### F. Settings UX updates

1. Update provider confirmation dialog to include impacted model names (`A / B / C`).
2. Keep settings lists active-only (do not render archived rows).
3. Ensure save/delete success and error status messages remain clear and localized.

### G. Tests and validation for Phase 0.5-1

1. Migration gate test: no startup auto-job before migration completion.
2. Migration compatibility test: upgrade from existing 1.x DB snapshot.
3. Provider archive cascade test: provider archive archives related models.
4. Reactivation test: archived provider/model row is reused on matching create.
5. Active query test: runtime candidate resolution excludes archived rows.
6. Reporting scope test: archived-linked usage rows remain queryable by default.

### H. Exit criteria for starting Phase 2

- Startup migration gate is enforced and verified.
- Archive lifecycle path is stable (archive/reactivate/query).
- No regressions in provider/model settings workflows.
- `./scripts/build` passes cleanly.

## Phase 2 — Usage fact table and write pipeline

1. Add `llm_usage_event` table + indexes.
2. Add write helper API (single event insert).
3. Instrument summary execution calls.
4. Instrument translation execution calls (chunk + repair + fallback).
5. Ensure all terminal statuses are captured.

Verification:
- One user action may produce multiple usage rows where expected.
- Token payload and missing-usage states are correctly persisted.

## Phase 3 — Retention policy

1. Add retention setting in app preferences.
2. Implement startup cleanup job for `llm_usage_event` (only after startup migration gate).
3. Add manual clear action (usage data only) in General settings near retention controls.

Verification:
- Expired rows are removed by policy.
- Manual clear action works and only affects usage data.
- Non-usage tables remain untouched.

## Phase 4 — Query APIs and aggregated DTOs

1. Implement aggregate SQL queries in database layer.
2. Add grouped results for task/provider/model dimensions.
3. Implement shared filter object and report DTOs.

Verification:
- Aggregates match raw-row sums.
- Archived provider/model rows are still reportable.

## Phase 5 — Usage UI (initial)

1. Add contextual `Statistics` button in the right pane for Provider/Model/Task sections.
2. Add `Statistics` icon button in section toolbar for dimension comparison view.
3. Build report view with cards/chart/lists and pre-applied filters.
4. Keep all strings localization-ready.

Verification:
- Multi-entry navigation always lands in same report shell with expected filters.
- Existing settings layout remains compact (no extra Usage tab).
- Large data sets keep UI responsive.

## Phase 6 — Hardening

1. Migration tests: old DB -> new schema.
2. Execution tests: status/phase correctness.
3. Query tests: aggregation and filtering correctness.
4. Regression tests for provider/model settings flows.

Stage acceptance:
- `./scripts/build` clean (no errors/warnings).

---

## Open Questions (intentionally left for later)

1. Should report views provide additional status presets beyond the default all-status scope?
2. Should retention add finer granularity options (for example, 14 days) after real usage feedback?
3. Should we add an export mechanism for raw usage events (CSV/JSON) for external analysis?

These do not block implementation.
