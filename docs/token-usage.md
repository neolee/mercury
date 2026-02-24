# Token Usage Tracking
    
*Implementation Baseline (updated to current code as of 2026-02-25)*

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
6. **Identity-ambiguity intervention is create-path only**.

---

## Current implementation status

Implemented in code:
- `llm_usage_event` schema + indexes + retention policy.
- Usage write pipeline for summary/translation request events.
- Shared usage report shell and shared comparison shell.
- Single-object report entry points for provider/model/agent-task.
- Comparison report entry points for provider/model/agent sections.
- Comparison data queries for provider/model/agent with fixed windows (`Last 1 Week` / `Last 2 Weeks` / `Last 1 Month`).

Still intentionally deferred in v1:
- Currency/cost estimation.
- Advanced custom report builder / pivot UX.
- Reader inline per-run token badge.

---

## Pre-Task (Completed): Provider/Model Lifecycle Refactor

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

5. **Non-create edits do not perform identity repair/merge**
     - For `baseURL` edits and other ambiguous identity-mixing operations, do not auto-merge or auto-relink historical rows.
     - We accept this boundary in v1 to keep behavior deterministic and avoid over-complex corrective logic.
     - Future disambiguation relies on request-time endpoint snapshots recorded in `llm_usage_event`.

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
- `providerResolvedURLSnapshot` (TEXT, nullable)
- `providerResolvedHostSnapshot` (TEXT, nullable)
- `providerResolvedPathSnapshot` (TEXT, nullable)
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

Endpoint snapshots rule:
- Persist the real outbound endpoint used for the request (sanitized, no credentials/query secrets).
- These snapshots are for historical traceability and later ambiguity resolution; they are not used for runtime identity correction in v1.

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

`taskRunId` linkage rule:
- `taskRunId` is nullable by schema, but runtime should link it whenever the corresponding `agent_task_run` row is available.
- `NULL` is fallback-only (for example, if run-row linkage cannot be established due to unexpected failure paths).

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

- Time range switch: `Last 1 Week` / `Last 2 Weeks` / `Last 1 Month`.
- Single-object report shell for provider/model/agent-task contexts.
- Comparison report shell for provider/model/agent dimensions.
- Comparison metric switch: `Requests` / `Up Tokens` / `Down Tokens` / `Tokens`.
- Summary row + chart + table in both report shells.
- Contextual statistics trigger buttons inside existing settings panes (no dedicated Usage tab).
- Usage aggregation includes all tracked statuses (`succeeded`, `failed`, `cancelled`, `timedOut`).

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
2. Add write helper API (single event insert + endpoint snapshot capture).
3. Instrument summary execution calls.
4. Instrument translation execution calls (chunk + repair + fallback).
5. Ensure all terminal statuses are captured.
6. Verify endpoint snapshot fields are populated from resolved request target.

Verification:
- One user action may produce multiple usage rows where expected.
- Token payload and missing-usage states are correctly persisted.
- Real request endpoint snapshots are persisted for later diagnostics.

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

## Single Provider Report (Implemented)

This section defines the first report implementation target: **single provider**.
Provider/model/agent comparison reports are also implemented and reuse a shared comparison shell.

### Scope

- Fixed context: one provider (pre-filtered from entry point).
- Time window options (fixed):
     - `Last 1 Week`
     - `Last 2 Weeks`
     - `Last 1 Month`
- Grouping baseline: daily buckets.
- Task split baseline in chart: `summary` and `translation`.

### Core metrics

Primary metrics (chart and summary):
- `requestCount`
- `promptTokens`
- `completionTokens`
- `totalTokens`

Quality/diagnostic metrics (summary panel):
- `successRate`
- `failedCount`
- `cancelledCount`
- `timedOutCount`
- `missingUsageCount`
- `missingUsageRate`
- `avgTokensPerRequest` (`totalTokens / requestCount`, guarded for zero)

### Metric definitions (strict)

- `requestCount`: count of rows in `llm_usage_event` after applying filters.
- `promptTokens`: sum of `promptTokens` over filtered rows, treating `NULL` as 0 for sum display.
- `completionTokens`: sum of `completionTokens` over filtered rows, treating `NULL` as 0.
- `totalTokens`: sum of `totalTokens` over filtered rows, treating `NULL` as 0.
- `missingUsageCount`: count of rows where `usageAvailability = missing`.
- `missingUsageRate`: `missingUsageCount / requestCount`.
- `successRate`: `succeededCount / requestCount`.

Status default scope:
- Include all likely billable and relevant traffic by default:
     - `succeeded`, `failed`, `cancelled`, `timedOut`.

### Chart design (single reusable composite)

Use one composite chart for the single-provider report:

- **Stacked bars** (left Y-axis, token unit):
     - lower segment: `promptTokens`
     - upper segment: `completionTokens`
     - bar total = `totalTokens`
- **Line overlay** (right Y-axis, request count unit):
     - `requestCount`

Rationale:
- Keeps token composition and traffic trend in one view.
- Avoids hidden normalization ambiguity by using explicit dual axes.

Interaction requirements:
- Hover tooltip for each day with exact values:
     - date
     - requestCount
     - prompt/completion/total tokens
     - status breakdown (optional in first pass, required in second pass)
- Legend must explicitly show units:
     - `Tokens (left axis)`
     - `Requests (right axis)`

### Aggregated summary panel (below chart)

Do not render a full daily detail table for now.
Instead, render compact aggregate blocks:

- Traffic block:
     - total requests
     - avg requests/day
- Token block:
     - total tokens
     - prompt/completion split
     - avg tokens/request
- Quality block:
     - success rate
     - failed/cancelled/timedOut counts
     - missing usage count and rate
- Trend block:
     - peak token day
     - peak request day
     - optional period-over-period delta vs previous equal-length window

### UI wireframe (text)

```text
+--------------------------------------------------------------------------------+
| Provider Statistics: <Provider Name> [Archived badge if needed]               |
| Window: [Last 1 Week v]    Chart Metric: [Composite (fixed for now)]          |
+--------------------------------------------------------------------------------+
|                                                                                |
|  Composite Chart                                                               |
|  - Stacked bars: Prompt + Completion tokens (left axis)                       |
|  - Line: Requests (right axis)                                                 |
|  - X axis: Day                                                                  |
|                                                                                |
+--------------------------------------------------------------------------------+
| Traffic:  Requests | Avg/day                                                   |
| Tokens :  Total | Prompt | Completion | Avg/request                            |
| Quality:  Success rate | Failed | Cancelled | TimedOut | Missing usage         |
| Trend  :  Peak token day | Peak request day | (Optional) vs previous window    |
+--------------------------------------------------------------------------------+
```

### Empty/error states

- No data in selected window:
     - show empty chart placeholder and message: `No usage data in this period.`
- Partial missing usage:
     - show non-blocking note with missing ratio.
- Query failure:
     - show inline retry area in report content.

### Acceptance criteria for this draft implementation

1. Fixed windows (`1w`, `2w`, `1m`) work and drive chart + summaries consistently.
2. Composite chart renders daily bars + line with correct dual-axis values.
3. Aggregate values equal raw-row sums under the same filter set.
4. Archived providers remain reportable.
5. Tooltip values match bucket data exactly.
6. Localization-ready strings for all new labels.

---

## Full Reporting Design (P4/P5 Contract)

This section finalizes the first complete reporting design across all planned report types.
Principle: **single-object reports first, comparison reports second, same report shell throughout**.

### Unified entry and iconography

- Right-pane statistics entry uses `chart.bar.xaxis`.
- Section-toolbar comparison entry uses `chart.line.uptrend.xyaxis`.
- Entry points:
     - Provider row/detail -> statistics icon.
     - Model row/detail -> statistics icon.
     - Agent/Task row/detail -> statistics icon.
     - Section toolbar -> comparison entry for the current dimension.
- All entries open the same report shell with pre-applied context filters.

### Report taxonomy

#### A. Single Provider Report

- Fixed provider, daily buckets, fixed window (`1w`/`2w`/`1m`).
- Chart: composite (stacked token bars + request line).
- Series split: task dimension (`summary`, `translation`).

#### B. Single Model Report

- Fixed model, daily buckets, fixed window (`1w`/`2w`/`1m`).
- Same chart design as single provider.
- Series split: task dimension.

#### C. Single Task Report

- Fixed task (`summary` or `translation`), daily buckets, fixed window.
- Chart: composite (stacked token bars + request line).
- Series split: provider (default Top N + Others) or model (user switch in advanced mode).

#### D. Provider/Model Comparison Report

- Dimension = provider or model.
- Metric selector (single-select):
     - `requestCount`, `promptTokens`, `completionTokens`, `totalTokens`.
- Chart: multi-series line chart by default.
- Limit: Top 6 series by selected metric total, plus optional `Others` aggregation.
- Token composition (prompt/completion split) is not shown in this chart; use summary table cards.

#### E. Task Comparison Report

- Compare `summary` vs `translation` under current scope.
- Metric selector (single-select) as above.
- Chart: two-series line chart (or grouped bars when user switches to bar mode in phase 2).

### Chart selection rules

To avoid configuration explosion for now, chart types are mostly fixed by report type.

- Single-object reports (A/B/C):
     - fixed composite chart (stacked bars + line).
- Comparison reports (D/E):
     - fixed bar chart for now.

Reasoning:
- single-object needs composition + traffic in one frame;
- comparison needs trend and cross-series readability.

### Tooltip and legend contract

Tooltip is required on all charts.

Minimum tooltip payload:
- bucket date
- selected/all series values
- units (`tokens`, `requests`)

Legend rules:
- always visible,
- supports series hide/show,
- preserves unit clarity for dual-axis charts.

### Filters and controls

Global controls in report shell header:
- Time window: `Last 1 Week` / `Last 2 Weeks` / `Last 1 Month`.
- Status scope preset:
     - default `All` (`succeeded`, `failed`, `cancelled`, `timedOut`),
     - optional quick preset `Succeeded only`.

Per-report controls:
- Single-object reports: no metric selector (composite fixed).
- Comparison reports: metric selector single-select.

Advanced controls (deferred):
- custom date range,
- multi-metric small multiples,
- chart-type manual switching.

### Summary panel contract (all report types)

Always render aggregate blocks below chart:

1. Traffic:
     - total requests,
     - avg requests/day.
2. Tokens:
     - total tokens,
     - prompt/completion totals,
     - avg tokens/request.
3. Quality:
     - success rate,
     - failed/cancelled/timedOut counts,
     - missing usage count and rate.
4. Trend:
     - peak token day,
     - peak request day,
     - optional delta vs previous equal-length window.

### Comparison readability constraints

- Max rendered series: 6 (plus optional `Others`).
- Color assignment must be stable by entity id (provider/model/task) across refreshes.
- Archived entities remain visible in historical reports with `Archived` badge in labels.

### Query and DTO requirements for P4

Introduce report-level query DTOs aligned to the taxonomy:

- `UsageReportFilter`
     - `windowPreset` (`1w`, `2w`, `1m`)
     - `statusSet`
     - `taskType?`
     - `providerId?`
     - `modelId?`
     - `comparisonDimension?` (`provider`, `model`, `task`)
     - `metric?` (for comparison reports)

- `UsageTimeBucketPoint`
     - `date`
     - `requestCount`
     - `promptTokens`
     - `completionTokens`
     - `totalTokens`
     - `statusCounts`

- `UsageAggregateSummary`
     - totals and ratios listed in summary panel contract.

- `UsageComparisonSeries`
     - `entityId`, `entityName`, `isArchived`
     - bucket values for selected metric.

### UI wireframes (text)

#### Single object shell (provider/model/task)

```text
+--------------------------------------------------------------------------------+
| Statistics: <Context Name> [Archived?]                                        |
| Window: [1w v]  Status: [All v]                                               |
+--------------------------------------------------------------------------------+
| Composite chart (stacked token bars + request line, daily buckets)            |
+--------------------------------------------------------------------------------+
| Traffic | Tokens | Quality | Trend summary blocks                             |
+--------------------------------------------------------------------------------+
```

#### Comparison shell (provider/model/task)

```text
+--------------------------------------------------------------------------------+
| Comparison: <Dimension>                                                       |
| Window: [1w v]  Status: [All v]  Metric: [Total Tokens v]                     |
+--------------------------------------------------------------------------------+
| Multi-series line chart (Top 6 + optional Others)                             |
+--------------------------------------------------------------------------------+
| Traffic | Tokens | Quality | Trend summary blocks                             |
+--------------------------------------------------------------------------------+
```

### Phased implementation recommendation

Follow this incremental rollout path to minimize UX risk and maximize component reuse.

#### Step 1 — Provider settings entry only (no comparison)

Goal:
- Add the statistics entry button in Provider settings surfaces and route into one report shell.

Implementation:
- Add `chart.bar.xaxis` statistics trigger at provider row/detail actions.
- Wire navigation to report shell with pre-applied `providerId` filter.
- Keep the page scaffold minimal (header + fixed window selector + loading/empty state).

Exit criteria:
- Every provider entry point opens the same report shell.
- Provider context is correctly preselected.
- Localization keys are complete.

#### Step 2 — Single Provider report (first full report)

Goal:
- Deliver end-to-end usable report for one provider.

Implementation:
- Implement daily aggregate queries for one provider under fixed windows (`1w`, `2w`, `1m`).
- Render composite chart (stacked prompt/completion bars + request line).
- Render summary blocks (traffic, token, quality, trend).
- Add tooltip and archived badge behavior.

Exit criteria:
- Aggregates match raw sums for the same filter set.
- Tooltip values match bucket data.
- Empty/error states are stable and understandable.

#### Step 3 — Provider comparison entry and report

Goal:
- Add provider-to-provider comparison only after single-provider quality is validated.

Implementation:
- Add toolbar statistics entry for provider comparison mode.
- Implement comparison query DTO (`comparisonDimension = provider`, metric single-select).
- Render multi-series line chart with Top 6 + optional `Others`.
- Reuse the same summary blocks and shell controls.

Exit criteria:
- Comparison route and filter state are deterministic.
- Series colors are stable by provider identity.
- Performance is acceptable with real dataset size.

#### Step 4 — Migrate same pattern to Model dimension

Goal:
- Reuse provider pipeline with model filter changes only.

Implementation:
- Add model statistics entry points.
- Reuse shell/chart/summary components.
- Switch query constraint from `providerId` to `modelId` (single) or `comparisonDimension = model` (comparison).

Exit criteria:
- No model-specific regressions in archived visibility and labels.
- Minimal code duplication relative to provider implementation.

#### Step 5 — Task dimension reports (single and comparison)

Goal:
- Complete the planned reporting matrix by adding task-oriented views.

Implementation:
- Add task statistics entry points.
- Implement single-task report under fixed windows.
- Implement task comparison (`summary` vs `translation`) with metric selector.
- Reuse all existing summary and status logic.

Exit criteria:
- Task views follow the same interaction contract as provider/model views.
- Status scope and metric definitions remain consistent across all dimensions.

#### Step 6 — Consolidation and hardening

Goal:
- Ensure consistency, localization, and maintainability before expanding advanced options.

Implementation:
- Unify shared report components and query interfaces.
- Add regression tests for filter routing, aggregate correctness, and archived semantics.
- Validate localization completeness for all report labels/tooltips/messages.

Exit criteria:
- `./scripts/build` is clean.
- End-to-end smoke checks pass for Provider -> Model -> Task routes.
- No stale localization entries introduced by report rollout.

### Final decisions captured

1. Time window is fixed presets (`1w`, `2w`, `1m`).
2. Single-object reports use one composite chart (stacked tokens + requests line).
3. Comparison reports use separate chart design (multi-series line), not the composite chart.
4. No daily raw table; tooltip + aggregate summary panel are the default read path.

---

## Open Questions (intentionally left for later)

1. Should report views provide additional status presets beyond the default all-status scope?
2. Should retention add finer granularity options (for example, 14 days) after real usage feedback?
3. Should we add an export mechanism for raw usage events (CSV/JSON) for external analysis?

These do not block implementation.
