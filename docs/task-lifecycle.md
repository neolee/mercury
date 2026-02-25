# Task Lifecycle Unification Plan

Date: 2026-02-25
Status: In progress (Step 0/1/2 complete; Step 3 partial)

## Key Goal (Top Priority)

Mercury must converge to one canonical task lifecycle model so that:

1. A task has one globally unique ID from creation to terminal state.
2. Timeout and cancel semantics are never ambiguous or reinterpreted across layers.
3. Exactly one component writes the terminal semantic outcome for each task.
4. Every layer has a single, explicit responsibility boundary.
5. Current behavior and future extensions can be reasoned about deterministically.

This is the primary objective of this refactor. Timeout fixes are a subset of this goal.

## Progress Snapshot (2026-02-25)

Goal status:
- Key goal remains valid; no target-level changes required.

What is complete:
- Step 0 ledger baseline is established.
- Step 1 identity unification core path is in place:
  - queue no longer mints task IDs,
  - app-level request boundary mints IDs,
  - runtime event emission no longer synthesizes fallback task IDs.
- Step 2 type/enum unification core path is in place:
  - canonical `UnifiedTaskKind` mapping utilities are implemented,
  - timeout kind conversions use canonical mapping helpers,
  - canonical `TaskTerminalOutcome` exists and is used by queue + agent terminal persistence paths.
- Timeout terminals now exist in queue/runtime/persistence enums.
- Queue timeout handling distinguishes `.timedOut` from `.cancelled`.
- Agent summary/translation failure/cancel terminal persistence is partially centralized in shared helpers.

What is still missing:
- Single terminal semantic writer is not fully enforced across all paths.
- Diagnostics and usage projection still have duplicate or divergent writers.

## 1. Problem Statement

Current implementation mixes multiple task concepts and terminal decision points:

- `TaskQueue` task (`AppTaskKind`) for execution scheduling.
- `AgentRuntimeEngine` run (`AgentTaskKind` + owner/slot) for reader lifecycle orchestration.
- persisted business task type (`AgentTaskType`) for storage/reporting.

These are valid views, but they are not bound to one canonical task identity and one terminal semantic source.
This causes semantic drift such as timeout showing as cancelled and inconsistent status across queue/runtime/persistence/UI.

## 2. Target Architecture

## 2.1 Canonical Task Object

Introduce a canonical envelope used across all layers:

- `UnifiedTaskID` (`UUID`) - single source ID
- `UnifiedTaskKind` (domain kind: `summary`/`translation`/`tagging`/...)
- request metadata (source, entry/slot owner, createdAt)

All existing task/run records become projections of this canonical object.

## 2.2 Canonical Terminal Outcome

Define one typed terminal contract, used end-to-end:

- `succeeded`
- `cancelled(source: .user)`
- `timedOut(origin: TimeoutOrigin)`
- `failed(reason: FailureReason, detail: ErrorDescriptor?)`

Where `TimeoutOrigin` includes at least:

- `execution`
- `networkRequest`
- `networkResource`
- `streamFirstToken`
- `streamIdle`

Rule: terminal outcome is immutable and can be written once only.

## 2.3 Layered Responsibilities (Authoritative)

### Layer A: Execution Control (`TaskQueue`)

Owns:

- execution slots and priority scheduling
- hard execution deadlines
- cooperative cancellation token plumbing

Does not own:

- user-facing failure meaning
- agent-specific phase lifecycle

Applies to:

- all task families, including non-agent tasks (`feed sync`, `import/export`, `reader build`, etc.).
- non-agent tasks should typically stop at this layer (no `AgentRuntimeEngine` participation).

### Layer B: Runtime Orchestration (`AgentRuntimeEngine`)

Owns:

- owner/entry/slot activation and waiting replacement
- runtime phase progression (`waiting/requesting/generating/persisting/...`)
- promotion from waiting to active

Does not own:

- low-level error classification
- timeout semantic inference
- terminal persistence writes

Applies to:

- agent tasks only (`summary`, `translation`, `tagging`) where owner/slot waiting and promotion semantics are required.
- non-agent tasks must not be routed here.

### Layer C: Task Semantics Orchestrator (Summary/Translation execution layer)

Owns:

- mapping low-level failures to canonical terminal outcome
- single terminal write for run persistence
- usage-link finalization
- emitting final reader-facing task event

Does not own:

- execution scheduling internals
- runtime queue replacement rules

### Layer D: Presentation (Reader views / projection)

Owns:

- rendering based on final mapped outcome and runtime projection

Does not own:

- scheduling decisions
- terminal semantic decisions

## 3. Truth Sources

Truth source is not one file for everything; it is one source per concern:

1. "Can this task execute now?" -> `TaskQueue`
2. "Which owner is active/waiting?" -> `AgentRuntimeEngine`
3. "What is the final semantic outcome?" -> execution orchestrator (single terminal writer)
4. "How to display it?" -> projection/UI

For non-agent tasks:

- `TaskQueue` + task execution orchestrator are sufficient.
- there is no runtime-owner truth source because owner/slot orchestration is not needed.

If a module answers two of these questions, boundaries are eroding.

## 4. Non-Compliant Points (Classified)

This section classifies all known mismatches against the target model. Refactor work is organized by these classes.

### Class A: Identity non-unification

Symptoms:
- runtime submit can generate IDs not aligned with queue task IDs.

Required unification:
- one `UnifiedTaskID` created once and reused by queue/runtime/persistence/telemetry/UI.

### Class B: Type/enum fragmentation

Symptoms:
- task kind concepts split across `AppTaskKind` / `AgentTaskKind` / `AgentTaskType` without a canonical mapping contract.
- timeout terminal semantics exist in some models but not others.

Required unification:
- canonical kind mapping table and canonical terminal type used by all projections.

### Class C: State-semantic divergence

Symptoms:
- timeout can be represented as failed/cancelled depending on layer.
- queue/runtime/persistence/usage may disagree for the same lifecycle.

Required unification:
- terminal semantic contract + deterministic projection rules per layer.

### Class D: Multi-writer terminal behavior

Symptoms:
- terminal semantics can be decided in multiple places (queue/provider/execution catch/UI path).

Required unification:
- single terminal writer rule: one place finalizes terminal outcome.

### Class E: Scheduling responsibility overlap

Symptoms:
- queue and runtime both gate execution/waiting behavior.
- waiting-limit knobs exist in more than one source.

Required unification:
- queue owns execution slots; runtime owns owner lifecycle only.
- one waiting policy source.

### Class F: Scope routing ambiguity

Symptoms:
- agent vs non-agent routing not centrally enforced.

Required unification:
- explicit family router:
  - non-agent tasks stop at queue plane,
  - agent tasks use queue + runtime planes.

### Class G: Observability and diagnostics inconsistency

Symptoms:
- usage timeout under-reported.
- duplicate debug issues can be written by generic and agent-specific paths.

Required unification:
- canonical terminal -> canonical telemetry/debug projection.

## 5. Required Invariants

These invariants are mandatory after refactor:

1. One `UnifiedTaskID` per lifecycle (creation -> terminal persistence -> telemetry -> UI).
2. One terminal semantic write per task.
3. Timeout is terminal and cannot be followed by cancelled.
4. Runtime phase and terminal outcome are compatible and monotonic.
5. Telemetry status and user-facing banner reason must be derived from the same terminal outcome.

## 6. Canonical Mapping Table (Must Exist Before Refactor Ends)

Define and keep updated in code + docs:

1. `UnifiedTaskKind` -> `AppTaskKind`
2. `UnifiedTaskKind` -> (`AgentTaskKind` or `none`)
3. `UnifiedTaskKind` -> `AgentTaskType` (for persisted agent tasks) or `none`
4. `TaskTerminalOutcome` -> queue state projection
5. `TaskTerminalOutcome` -> runtime phase projection (agent only)
6. `TaskTerminalOutcome` -> persistence status projection
7. `TaskTerminalOutcome` -> usage status projection
8. `TaskTerminalOutcome` -> banner/debug projection

No implicit conversion is allowed outside this mapping layer.

## 7. Implementation Plan (Category-Driven, Deliverable-First)

The plan is intentionally organized by non-compliant classes (A-G), not by file or subsystem.

### Step 0: Baseline Inventory and Non-Compliance Ledger

Scope:
- create a machine-checkable ledger listing every current enum/type/ID/state field involved in lifecycle.
- map each item to Class A-G.

Deliverables:
- `docs/task-lifecycle-ledger.md` with table: `artifact`, `current_role`, `target_role`, `class`, `owner`.
- failing checks (or TODO markers) for missing canonical mappings.

Acceptance:
- every task-related type and terminal path is listed exactly once.

### Step 1: Identity Unification (Class A)

Scope:
- introduce `UnifiedTaskID` and ensure creation at task request boundary.
- runtime submit and queue enqueue consume the same ID.
- persistence and telemetry link to this ID lineage.

Deliverables:
- one constructor path for task identity.
- removal of auto-generated independent runtime IDs for same lifecycle.

Acceptance:
- trace a task from request -> queue -> runtime -> persistence -> banner with one ID.

### Step 2: Type/Enum Unification (Class B)

Scope:
- introduce `UnifiedTaskKind`.
- add canonical mapping table utilities and replace ad-hoc conversions.
- align terminal representation type (`TaskTerminalOutcome`) as the semantic source.

Deliverables:
- mapping module used by all projections.
- deprecated old direct cross-enum conversions behind shim APIs only.

Acceptance:
- no direct business logic depends on multiple kind enums without canonical mapping helper.

### Step 3: Single Terminal Writer and Semantic Determinism (Classes C + D)

Scope:
- enforce one terminal writer per task (orchestrator).
- provider/queue/runtime may report signals, but not finalize semantic terminal outcome.
- remove duplicate terminal writes and terminal event races.

Deliverables:
- terminal finalization service/API used by summary/translation.
- deduplicated terminal persistence + usage linking path.

Acceptance:
- each task lifecycle emits exactly one terminal semantic outcome.
- timeout cannot appear as cancelled in final mapped result.

### Step 4: Scheduling and Policy Boundary Unification (Classes E + F)

Scope:
- explicit task-family router:
  - non-agent tasks: queue plane only.
  - agent tasks: queue + runtime planes.
- queue owns execution slot scheduling.
- runtime owns owner lifecycle and waiting replacement for agent tasks.
- unify waiting-limit source of truth.

Deliverables:
- routing adapter/factory with test coverage.
- removal of duplicate scheduling authority and ambiguous waiting knobs.

Acceptance:
- non-agent tasks never touch runtime owner state.
- agent tasks follow one clear two-plane route.

### Step 5: Observability and Diagnostics Unification (Class G)

Scope:
- ensure timeout outcomes write timeout telemetry status.
- remove duplicate/competing debug issue writers for agent tasks.
- banner/debug/usage all derive from canonical terminal outcome.

Deliverables:
- canonical projection functions for telemetry and debug surfaces.
- updated failure/debug policy for agent vs non-agent tasks.

Acceptance:
- same task outcome appears consistently in queue UI, banner, DB run status, and usage records.

### Step 6: Hardening and Regression Gates

Scope:
- integration matrix for agent tasks:
  - user abort, execution timeout, request timeout, resource timeout, first-token timeout, idle timeout.
- non-agent matrix:
  - feed sync/import/export timeout-cancel-failure scenarios.

Assertions:
- ID consistency,
- terminal outcome consistency,
- layer-specific projection consistency.

Acceptance:
- CI gates fail on any semantic divergence.

## 8. Immediate Stabilization Actions (Before Full Refactor)

1. Apply intended execution timeout defaults (`summary=180s`, `translation=300s`).
2. Apply intended network/stream timeout defaults:
   - `requestTimeout=120s`
   - `resourceTimeout=600s`
   - `streamFirstTokenTimeout=120s`
   - `streamIdleTimeout=60s`
3. Ensure timeout-like cancellation is not collapsed to user-cancel semantics.
4. Stop generic duplicate debug-issue insertion for agent failures where a canonical agent surface already exists.
5. Keep non-agent tasks on `TaskQueue` path only; do not add runtime-engine dependencies for them.

These are temporary stabilizers, not final architecture.

## 9. Stable Path (Recommended Execution Order)

For maximal stability and minimal rework:

1. Step 0 -> Step 1 first (inventory and identity), because all later changes depend on traceability.
2. Step 2 next (kind/terminal types), to stop further semantic spread.
3. Step 3 before any broad UI adjustments, so semantic source is centralized early.
4. Step 4 after semantic centralization, to avoid dual-authority regressions.
5. Step 5 and Step 6 last, as convergence and guardrails.

This order ensures each step reduces ambiguity and makes subsequent steps simpler.

## 10. Scope of This Document

This document is the implementation contract for task-lifecycle unification, not only timeout handling.
All future task-related changes should be evaluated against the ownership model and invariants defined above.
