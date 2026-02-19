# Agent Shared Architecture Memo

> Date: 2026-02-19
> Last updated: 2026-02-19
> Status: Draft for implementation

## 1. Purpose
- Define the reusable architecture and runtime contracts shared by all spec-driven AI agents (`summary`, `translation`, future agents).
- Avoid re-implementing scheduling, lifecycle, failure handling, and UI state projection for each new agent.
- Keep task-specific logic isolated so agents can evolve independently without duplicating platform mechanics.

## 2. Existing Assets in Current Codebase

The following pieces already exist and have proven behavior through summary implementation:

- Queue and task state infrastructure:
  - `TaskQueue` / `TaskCenter` with per-kind concurrency limits and observable events.
- Shared run/persistence foundation:
  - `ai_task_run` lifecycle/provenance model.
- Summary execution and storage flow:
  - `AppModel+AISummaryExecution.swift`
  - `AppModel+AISummaryStorage.swift`
- Summary policy modules:
  - `SummaryAutoPolicy`
  - `SummaryAutoStartPolicy`
  - `SummaryStreamingCachePolicy`
- Reader integration patterns:
  - in-flight slot ownership
  - waiting status projection
  - fail-closed fetch gate (`Fetch data failed. Retry?`)

These are not fully generic yet, but they provide direct extraction candidates.

## 3. Shared vs Agent-specific Boundaries

## 3.1 Must be shared (agent-agnostic)
- `AgentRunCoordinator`
  - queue binding and serialized/parallel policy control
  - waiting lifecycle (`queued`, `waiting`, `abandoned`, `started`, `terminal`)
  - active owner identity (`agentTaskType + entryId + slotKey`)
  - explicit cancellation/abort handling
  - timeout/watchdog hooks and terminal reason mapping
- `AgentRunStateMachine`
  - canonical states:
    - `idle`
    - `waiting`
    - `requesting`
    - `generating`
    - `persisting`
    - `completed`
    - `failed`
    - `cancelled`
    - `timedOut`
- `AgentRunProjection`
  - transforms coordinator state into UI-safe display model
  - guarantees entry/slot isolation
  - defines waiting display rules and abandonment behavior
- `AgentFailureClassifier`
  - normalize execution/storage/parser/provider failures into stable reason codes.

## 3.2 Must stay agent-specific
- slot key schema:
  - summary: `entry + language + detailLevel`
  - translation: `entry + language + sourceHash + segmenterVersion`
- request construction and parsing:
  - prompt payload shape
  - model output contract
  - recovery strategy from malformed outputs
- payload persistence structure:
  - summary single text payload
  - translation segment-mapped payload
- display composition:
  - summary panel text
  - translation inline bilingual blocks.

## 4. Contract Baselines for All Agents

- No hidden start:
  - if a task starts, there must be a user-visible state transition.
- Deterministic ownership:
  - every in-flight run must resolve to exactly one `(entryId, slotKey)` owner.
- Fail-closed data fetch:
  - read failures must block implicit start and show explicit retry affordance.
- Explicit waiting semantics:
  - waiting is first-class state, never inferred from side effects.
- Abandon-on-leave support:
  - if product contract enables abandonment, coordinator handles it directly.
- Terminal-state completeness:
  - all runs end as exactly one of `completed/failed/cancelled/timedOut`.

## 5. Translation-specific Policy on Top of Shared Contract

- Translation v1 is manual-only:
  - entry switch resets to `Original`.
  - no auto-translate trigger.
- Translation scheduling:
  - serialized by default (`translation kind limit = 1`).
- Waiting abandonment:
  - waiting intent is dropped when user leaves entry before start.
- Progress model:
  - phase-based projection plus chunk progress (`i/n`) where available.

## 6. Extraction and Adoption Plan

### Phase A — Inventory and API freeze
1. Identify summary logic that is already generic in behavior but summary-named in code.
2. Freeze shared protocol interfaces:
   - `AgentRunCoordinatorProtocol`
   - `AgentExecutorProtocol`
   - `AgentResultStoreProtocol`
   - `AgentRunProjectionProtocol`
3. Define migration compatibility shims so summary keeps behavior during refactor.

Gate:
- no behavior change in summary baseline tests.

### Phase B — Implement shared coordinator
1. Introduce agent-agnostic coordinator and state machine module.
2. Bind to existing `TaskQueue`/`TaskCenter` event stream.
3. Add timeout/watchdog and normalized error mapping.

Gate:
- coordinator tests pass for state transitions and queue semantics.

### Phase C — Migrate summary to shared coordinator
1. Replace summary-local run state orchestration with shared coordinator.
2. Keep summary-specific executor/parser/storage adapters unchanged initially.
3. Verify no UX regression in summary panel behavior.

Gate:
- summary regression tests pass with no behavior drift.

### Phase D — Migrate translation to shared coordinator
1. Apply manual-only and waiting-abandon rules through coordinator policy switches.
2. Connect translation executor/parser/storage adapters.
3. Replace ad-hoc view-level state stitching with coordinator projection.

Gate:
- translation stale `Generating` and cross-entry confusion issues are closed.

### Phase E — Extend for future agents
1. New agent onboarding requires only:
   - slot schema
   - executor/parser
   - result persistence
   - UI composition adapter
2. Shared coordinator remains unchanged except policy configuration.

Gate:
- add-one-agent integration checklist is one page and repeatable.

## 7. Test Matrix (High Priority Unit Tests)

- `AgentRunStateMachineTests`
  - legal/illegal transitions
  - terminal-state guarantees
  - timeout/cancel behavior
- `AgentRunCoordinatorQueueTests`
  - serialized waiting behavior
  - abandon waiting on leave
  - entry/slot ownership isolation
- `AgentRunProjectionTests`
  - status text/progress projection for selected vs non-selected entries
- `AgentFailureClassifierTests`
  - mapping raw errors to stable user-facing categories
- `SummaryCoordinatorIntegrationTests`
  - summary behavior parity after migration
- `TranslationCoordinatorIntegrationTests`
  - manual-only start, waiting rules, and no stale generating after completion/failure

## 8. Non-goals
- Unifying all agent payload schemas into one polymorphic table in this phase.
- Introducing auto behaviors for translation.
- Adding high-concurrency translation as default policy.
