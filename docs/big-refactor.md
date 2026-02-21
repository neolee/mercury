# Big Refactor Plan (Agent Runtime Unification)

Date: 2026-02-20
Status: Draft (execution-oriented)

## 1. Goal

This document defines a full refactor plan to:

1. Fully centralize agent runtime state management and scheduling logic.
2. Remove fragmented task state handling from UI layers.
3. Normalize naming conventions across agent-related source files.
4. Build a stable target file structure with clear ownership and migration steps.

This plan is intentionally architecture-first and does not optimize for minimal change.

---

## 2. Naming Normalization Rules (Authoritative)

Scope note (global rule):

- Naming normalization is global and must be applied consistently to all code elements, not only file names.
- Required rename scope includes at least:
    - file names
    - type names (`struct`/`class`/`enum`/`protocol`)
    - function/method names
    - property/variable/parameter names
    - constants/static members
    - related test suite/test case names when they encode old naming
    - user-facing/internal identifier keys where symbol naming is part of architectural taxonomy
- During migration, symbol renames must stay synchronized with file renames in the same phase to avoid mixed old/new taxonomy.

### 2.1 Prefix rules

- Shared, cross-agent runtime/platform modules must use `Agent*` prefix.
- Agent-specific modules must use agent-name prefix:
  - `Summary*`
  - `Translation*`
- `AI*` prefix is deprecated and must be eliminated from source file names and symbol names in this scope.

### 2.2 AppModel extension rules

- Replace `AppModel+AI*.swift` with normalized feature names (remove `AI`):
  - `AppModel+AgentSettings.swift`
  - `AppModel+SummaryExecution.swift`
  - `AppModel+SummaryStorage.swift`
  - `AppModel+TranslationExecution.swift`
  - `AppModel+TranslationStorage.swift`

### 2.3 Provider naming

- Keep SwiftOpenAI provider in the unified agent stack.
- Normalize provider file/symbol naming to the shared prefix convention:
    - `SwiftOpenAILLMProvider.swift` -> `AgentLLMProvider.swift`
    - `SwiftOpenAILLMProvider` -> `AgentLLMProvider`

### 2.4 Mandatory merge decisions (confirmed)

The following 5 merge decisions are mandatory in this refactor:

1. Merge `AgentRuntimeProjection` + `AgentDisplayProjection` + `AgentFailureMessageProjection` into one runtime projection module.
2. Merge `AgentEntryActivationPipeline` + `AgentEntryActivationCoordinator` into one activation module.
3. Merge `AISummaryPromptCustomization` + `AITranslationPromptCustomization` (+ adapters) into one shared `AgentPromptCustomization` module.
4. Merge `SummaryAutoPolicy` + `SummaryWaitingPolicy` into one `SummaryPolicy` module.
5. Merge execution/storage pairs by feature to simplify maintenance:
     - `SummaryExecution` + `SummaryStorage` -> `SummaryRuntime`
     - `TranslationExecution` + `TranslationStorage` -> `TranslationRuntime`

Execution note:

- Decision 5 is a post-MVP consolidation target.
- Architecture C baseline in section 9 keeps execution/storage split during runtime-lifecycle unification to reduce migration risk.

---

## 3. Current File Inventory and Decision (All Covered)

Legend:
- **Keep**: keep as-is (possibly move/rename only)
- **Refactor**: keep behavior but restructure responsibilities
- **Merge**: merge into another module
- **Remove**: remove obsolete module

## 3.1 Shared runtime modules (`Agent*`)

1. `AgentRunCore.swift`
   - Role: run/task core types (`AgentTaskKind`, owner, phase, snapshot).
   - Status: actively used.
   - Decision: **Keep + Refactor** (canonical runtime model types).

2. `AgentRunStateMachine.swift`
   - Role: legal transition rules.
   - Status: actively used.
   - Decision: **Keep** (single transition authority).

3. `AgentRunCoordinator.swift`
   - Role: active/waiting queue + promote + state storage.
   - Status: actively used but currently called directly from UI.
   - Decision: **Refactor** into `AgentRuntimeEngine` internals; UI direct calls must be removed.

4. `AgentEntryActivationPipeline.swift`
   - Role: persisted-first decision logic.
   - Status: actively used.
   - Decision: **Keep**.

5. `AgentEntryActivationCoordinator.swift`
   - Role: activation orchestration wrapper.
   - Status: actively used.
   - Decision: **Keep + Refactor** (consume new runtime APIs).

6. `AgentDisplayProjection.swift`
   - Role: placeholder projection utility.
   - Status: used, but input composition still spread in UI.
    - Decision: **Merge** into unified `AgentRuntimeProjection`.

7. `AgentFailureClassifier.swift`
   - Role: normalized failure reason classification.
   - Status: actively used.
   - Decision: **Keep**.

8. `AgentFailureMessageProjection.swift`
   - Role: reason -> user message mapping.
   - Status: actively used.
    - Decision: **Merge** into unified `AgentRuntimeProjection`.

## 3.2 Agent foundation / provider / templates (`AI*` currently)

9. `AIFoundation.swift`
   - Role: LLM provider protocol, credential store, base request/response.
   - Status: partially used (`LLMProvider`, `CredentialStore` used; `AIOrchestrator` not implemented).
   - Decision: **Rename + Refactor** -> `AgentFoundation.swift`.

10. `AIProviderValidation.swift`
    - Role: provider/model connectivity checks.
    - Status: actively used in settings.
    - Decision: **Rename + Keep** -> `AgentProviderValidation.swift`.

11. `AIPromptTemplateStore.swift`
    - Role: YAML template loading/validation/rendering.
    - Status: actively used by summary/translation customization.
    - Decision: **Rename + Keep** -> `AgentPromptTemplateStore.swift`.

12. `SwiftOpenAILLMProvider.swift`
    - Role: production OpenAI-compatible adapter via SwiftOpenAI.
    - Status: actively used.
    - Decision: **Rename + Keep** -> `AgentLLMProvider.swift`.

## 3.3 Translation-specific modules (`AITranslation*` currently)

13. `AITranslationContracts.swift`
    - Role: translation policy constants, slot contracts, statuses.
    - Status: actively used.
    - Decision: **Rename + Keep** -> `TranslationContracts.swift`.

14. `AITranslationModePolicy.swift`
    - Role: translation/original mode toggle policy.
    - Status: actively used.
    - Decision: **Rename + Keep** -> `TranslationModePolicy.swift`.

15. `AITranslationHeaderTextBuilder.swift`
    - Role: title/byline header source builder.
    - Status: actively used.
    - Decision: **Rename + Keep** -> `TranslationHeaderTextBuilder.swift`.

16. `AITranslationSegmentExtractor.swift`
    - Role: deterministic translation segment extraction.
    - Status: actively used.
    - Decision: **Rename + Keep** -> `TranslationSegmentExtractor.swift`.

17. `AITranslationBilingualComposer.swift`
    - Role: render translated blocks into reader HTML.
    - Status: actively used.
    - Decision: **Rename + Keep** -> `TranslationBilingualComposer.swift`.

18. `AITranslationPromptCustomization.swift`
    - Role: translation custom prompt file workflow.
    - Status: actively used.
    - Decision: **Merge** with summary customization into shared agent prompt customization service.

19. `AITranslationStartPolicy.swift`
    - Role: start decision helper.
    - Status: test-only (not used in production path).
    - Decision: **Remove** (or absorb logic into runtime activation policy if needed).

## 3.4 Summary-specific modules

20. `SummaryLanguageOption.swift`
    - Role: language normalization + supported options.
    - Status: actively used by summary and translation defaults.
    - Decision: **Keep** (or optionally rename to `AgentLanguageOption` in later phase).

21. `SummaryAutoPolicy.swift`
    - Role: summary auto-run control policy helpers.
    - Status: actively used.
    - Decision: **Merge** into `SummaryPolicy.swift`.

22. `SummaryWaitingPolicy.swift`
    - Role: summary waiting replacement strategy.
    - Status: actively used.
    - Decision: **Merge** into `SummaryPolicy.swift`.

23. `SummaryStreamingCachePolicy.swift`
    - Role: streaming state eviction policy.
    - Status: actively used.
    - Decision: **Keep**.

24. `SummaryAutoStartPolicy.swift`
    - Role: wrapper around activation decision.
    - Status: test-only (not used in production path).
    - Decision: **Remove**.

25. `AISummaryPromptCustomization.swift`
    - Role: summary custom prompt workflow.
    - Status: actively used.
    - Decision: **Merge** with translation customization into shared service.

## 3.5 AppModel AI-related extensions

26. `AppModel+AI.swift`
    - Role: settings/domain APIs for provider/model/agent defaults.
    - Decision: **Rename + Keep** -> `AppModel+AgentSettings.swift`.

27. `AppModel+AISummaryExecution.swift`
    - Role: summary execution pipeline.
    - Decision: **Rename + Refactor** -> `AppModel+SummaryExecution.swift`.

28. `AppModel+AISummaryStorage.swift`
    - Role: summary persistence/query.
    - Decision: **Rename + Keep** -> `AppModel+SummaryStorage.swift`.

29. `AppModel+AITranslationExecution.swift`
    - Role: translation execution pipeline.
    - Decision: **Rename + Refactor** -> `AppModel+TranslationExecution.swift`.

30. `AppModel+AITranslationStorage.swift`
    - Role: translation persistence/query.
    - Decision: **Rename + Keep** -> `AppModel+TranslationStorage.swift`.

## 3.6 Other shared app runtime files explicitly reviewed

31. `FailurePolicy.swift`
    - Role: user-facing error surfacing and feed failure classification.
    - Decision: **Keep + Extend** (agent failure surfacing policy alignment).

32. `JobRunner.swift`
    - Role: timed async job wrapper with event stream.
    - Decision: **Keep**.

33. `TaskQueue.swift`
    - Role: global task execution scheduler + task center bridge.
    - Decision: **Keep + Clarify boundary** (execution scheduler only; agent lifecycle remains in `AgentRuntimeEngine`).

---

## 4. Target File List (Final State) with Source Mapping

Scope note:

- This section describes long-term post-MVP target structure.
- Current execution baseline and authoritative near-term implementation scope are defined in section 9.

## 4.1 Shared agent runtime domain

1. `AgentFoundation.swift`
   - Source: rename from `AIFoundation.swift`.

2. `AgentLLMProvider.swift`
   - Source: rename from `SwiftOpenAILLMProvider.swift`.

3. `AgentProviderValidation.swift`
   - Source: rename from `AIProviderValidation.swift`.

4. `AgentPromptTemplateStore.swift`
   - Source: rename from `AIPromptTemplateStore.swift`.

5. `AgentPromptCustomization.swift` (new)
   - Source: merge from `AISummaryPromptCustomization.swift` + `AITranslationPromptCustomization.swift`.

6. `AgentRunCore.swift`
   - Source: keep.

7. `AgentRunStateMachine.swift`
   - Source: keep.

8. `AgentRuntimeStore.swift` (new)
   - Source: new (single source-of-truth for run state snapshots and ownership).

9. `AgentRuntimeEngine.swift` (new)
   - Source: extracted/expanded from `AgentRunCoordinator.swift` + View-level scheduling logic.

10. `AgentEntryActivation.swift` (new)
    - Source: merge from `AgentEntryActivationPipeline.swift` + `AgentEntryActivationCoordinator.swift`.

11. `AgentRuntimeProjection.swift` (new)
    - Source: merge/expand from `AgentRuntimeProjection` design + `AgentDisplayProjection.swift` + `AgentFailureMessageProjection.swift` + status mapping logic currently spread in `ReaderDetailView`.

12. `AgentFailureClassifier.swift`
    - Source: keep.

13. `AgentFeaturePolicy.swift` (new)
    - Source: extract generic waiting/replacement policy primitives currently duplicated in summary/translation handling.

## 4.2 Summary feature domain

Note: `SummaryRuntime.swift` is a post-MVP consolidation target after section 9 runtime invariants are stabilized.

17. `SummaryRuntime.swift` (new)
    - Source: merge from summary execution + summary storage modules.

18. `SummaryPolicy.swift` (new)
    - Source: merge from `SummaryAutoPolicy.swift` + `SummaryWaitingPolicy.swift`.

21. `SummaryStreamingCachePolicy.swift`
    - Source: keep.

22. `SummaryLanguageOption.swift`
    - Source: keep.

23. `SummaryPromptCustomizationAdapter.swift` (new)
    - Source: wraps `AgentPromptCustomization` for summary conventions.

24. `SummaryAutoStartPolicy.swift`
    - Source: remove.

## 4.3 Translation feature domain

Note: `TranslationRuntime.swift` is a post-MVP consolidation target after section 9 runtime invariants are stabilized.

25. `TranslationContracts.swift`
   - Source: rename from `AITranslationContracts.swift`.

26. `TranslationModePolicy.swift`
   - Source: rename from `AITranslationModePolicy.swift`.

27. `TranslationHeaderTextBuilder.swift`
   - Source: rename from `AITranslationHeaderTextBuilder.swift`.

28. `TranslationSegmentExtractor.swift`
   - Source: rename from `AITranslationSegmentExtractor.swift`.

29. `TranslationBilingualComposer.swift`
   - Source: rename from `AITranslationBilingualComposer.swift`.

30. `TranslationRuntime.swift` (new)
    - Source: merge from translation execution + translation storage modules.

31. `TranslationPromptCustomizationAdapter.swift` (new)
   - Source: wraps `AgentPromptCustomization` for translation conventions.

32. `TranslationStartPolicy.swift`
   - Source: remove (`AITranslationStartPolicy.swift` test-only).

## 4.4 AppModel extension surface

34. `AppModel+AgentSettings.swift`
   - Source: rename from `AppModel+AI.swift`.

35. `AppModel+SummaryExecution.swift`
    - Source: rename from `AppModel+AISummaryExecution.swift`.

36. `AppModel+SummaryStorage.swift`
    - Source: rename from `AppModel+AISummaryStorage.swift`.

37. `AppModel+TranslationExecution.swift`
    - Source: rename from `AppModel+AITranslationExecution.swift`.

38. `AppModel+TranslationStorage.swift`
    - Source: rename from `AppModel+AITranslationStorage.swift`.

---

## 5. ReaderDetailView Refactor Boundary

`ReaderDetailView` must no longer own agent runtime truth.

Current anti-patterns to remove:
- pending-run maps in view state
- direct calls to coordinator transition APIs
- promoted-owner scheduling/abandon logic in view
- manual assembly of phase/status projection in view

Target:
- `ReaderDetailView` only reads a projection model and dispatches feature intents.
- Runtime state and scheduling are owned by `AgentRuntimeEngine` + feature adapters.

Suggested split:
- `ReaderDetailContainerView.swift` (layout + composition)
- `ReaderSummaryPanelView.swift` (summary UI only)
- `ReaderTranslationPaneView.swift` (translation UI only)
- `ReaderDetailViewModel.swift` (non-agent UI state only)
- `ReaderAgentBridge.swift` (intent dispatch + state subscription)

---

## 6. Implementation Plan (Step-by-Step)

## Phase 0 — Freeze naming and boundaries (no behavior change)

1. Approve naming rules and target file list from this document.
2. Add temporary compatibility aliases where needed to keep build green during rename chain.
3. Mark to-be-removed files as deprecated in comments (English only).

Exit criteria:
- Team alignment on authoritative file targets.

## Phase 1 — Rename pass (first-class task)

1. Rename files/symbols:
   - `AIFoundation` -> `AgentFoundation`
   - `AIProviderValidation` -> `AgentProviderValidation`
   - `AIPromptTemplateStore` -> `AgentPromptTemplateStore`
    - `SwiftOpenAILLMProvider` -> `AgentLLMProvider`
   - `AITranslation*` -> `Translation*`
   - `AppModel+AI*` -> `AppModel+Agent/ Summary/ Translation*`
2. Update all call sites and tests.
3. Keep behavior unchanged.

Exit criteria:
- `./build` succeeds.
- No `AI*`-prefixed runtime files remain in this scope except intentional compatibility stubs (if temporarily needed).

## Phase 2 — Remove test-only/obsolete wrappers

1. Remove:
   - `SummaryAutoStartPolicy.swift`
   - `AITranslationStartPolicy.swift`
2. Remove merged source files after successor modules compile:
    - `AgentDisplayProjection.swift`
    - `AgentFailureMessageProjection.swift`
    - `AgentEntryActivationPipeline.swift`
    - `AgentEntryActivationCoordinator.swift`
    - `SummaryAutoPolicy.swift`
    - `SummaryWaitingPolicy.swift`
3. Move/replace corresponding tests to runtime activation/projection/policy coverage.

Exit criteria:
- No production-unreferenced wrapper policies remain.

## Phase 3 — Build centralized runtime truth source

1. Add `AgentRuntimeStore.swift` and `AgentRuntimeEngine.swift`.
2. Move queue ownership, waiting/promote rules, terminal completion, timeout/watchdog hooks into engine.
3. `AgentRunCoordinator` becomes internal helper or is absorbed by engine.

Exit criteria:
- All run transitions are executed through runtime engine APIs.
- Every run has deterministic owner and terminal phase.

## Phase 4 — Introduce unified projection model

1. Add/complete `AgentRuntimeProjection.swift` to produce UI-safe state.
2. Migrate status/message mapping from view code into projection.
3. Remove compatibility projection modules after migration.

Exit criteria:
- View no longer constructs phase/status from raw internal maps.

## Phase 5 — Feature adapter migration

1. Add summary/translation adapters for execute/parse/persist specifics.
2. Route both features through the same runtime lifecycle APIs.
3. Keep feature-specific slot schemas and render adapters only.

Exit criteria:
- Summary/translation share one runtime lifecycle path.

## Phase 6 — ReaderDetailView decomposition

1. Split UI into container + feature panes + bridge.
2. Remove view-owned queue/pending/promote/abandon logic.
3. Use runtime projection subscription only.
4. Execute orphan cleanup during decomposition:
    - delete compatibility scheduler hooks that are no longer reachable
    - remove feature-local pending payload/state caches that no longer serve rendering
    - remove dead helper functions kept only for pre-migration promotion chains

Exit criteria:
- `ReaderDetailView` is presentation-focused and significantly reduced.

## Phase 7 — Cleanup and hardening

1. Remove compatibility aliases.
2. Remove deprecated files.
3. Add/upgrade tests:
   - transition legality
   - waiting abandon and promotion
   - cross-entry isolation
   - clear scope consistency
   - timeout/failure recovery

Exit criteria:
- No duplicate lifecycle logic remains.
- Runtime behavior is fully test-covered for core non-UI flows.

---

## 7. Risk Controls

1. Rename risk: use phased compatibility aliases for one phase only.
2. Runtime migration risk: preserve per-`taskKind` queue baseline during migration (concurrent active limit `1`, waiting capacity `1`).
3. UI drift risk: lock user-visible status wording in projection tests.
4. Data safety risk: do not change storage schema while doing naming/runtime unification; schema changes are separate tasks.
5. Concurrency isolation risk: under compiler `default-isolation=MainActor`, runtime/value modules used by actors must explicitly declare `nonisolated` for pure value types and static policy/projection utilities.

---

## 8. Immediate Next Actions

1. Execute Phase 1 rename pass as a dedicated PR batch.
2. Execute Phase 2 cleanup (remove test-only wrappers).
3. Start Phase 3 runtime engine extraction with translation path first (highest current bug impact).
4. Execute Phase 5 by moving summary/translation onto shared runtime execution facilities and adapters.

### Execution Notes (2026-02-21)

- Phase 4 status/message projection migration is complete in `ReaderDetailView` and uses `AgentRuntimeProjection` as the shared source.
- Phase 5 has started with shared execution facilities:
    - shared route candidate resolution for `summary`/`translation`
    - shared terminal `agent_task_run` failure/cancel recording
    - shared language display + runtime snapshot encoding utilities

---

## 9. Architecture Detailed Blueprint (Authoritative Review Baseline)

Date: 2026-02-21
Status: Proposed (review + execution baseline)

This chapter defines the concrete design and execution blueprint for the agent core architecture.
It is mandatory for follow-up implementation and supersedes any ad-hoc view-driven scheduling logic.

### 9.1 Problem Statement (Current Gap)

Current runtime ownership is split:

- Runtime engine/store manage active/waiting snapshots and transitions.
- `ReaderDetailView` still keeps feature-local pending/running lifecycle truth and promotion handlers.

This double-source pattern causes race windows and state contamination risk (cross-entry projection overwrite).

Required correction:

- One single truth for task lifecycle must exist in runtime domain only.
- View must be intent emitter + projection consumer only.

### 9.2 Authoritative Architecture (Data-Centric)

#### A) Runtime Domain (single truth)

Runtime domain owns:

- submit/start decisions
- waiting queue operations
- legal phase transitions
- terminal state writeback
- promotion (`finish -> promote -> activate`) atomically

#### B) Task Executors (feature-specific only)

Feature executors (`summary` / `translation`) own only:

- request payload assembly
- provider invocation
- parse/persist specifics
- streaming token/progress reporting

Executors must not own queue truth.

#### C) Projection Domain (UI-safe read model)

Projection service consumes runtime events/snapshots and yields:

- visible projection (selected entry scope)
- global projection (debug/diagnostic scope)

#### D) View Domain (passive)

View responsibilities:

- dispatch intents (`submit`, `cancel`, `clear`, `retry`)
- render projection

View must not:

- keep pending owner maps as lifecycle truth
- perform promotion chain logic
- synthesize run lifecycle by combining local state + partial runtime calls

### 9.3 Unified Task Data Structures (Step 1 Core Deliverable)

Define a canonical runtime task model (new or extended on top of existing `AgentRun*` models):

1. `AgentTaskID`
    - Type: `UUID`
    - Purpose: stable identity per submitted task instance.

2. `AgentTaskOwner`
    - Existing: `AgentRunOwner(taskKind, entryId, slotKey)`
    - Purpose: task-to-entry binding and slot-scoped UI projection key.
    - Notes:
        - `owner` is not task instance identity.
        - `owner` is used for selected-entry visibility decisions and feature-slot routing.

3. `AgentTaskSpec` (new)
    - `taskId: AgentTaskID`
    - `owner: AgentTaskOwner`
    - `requestSource: manual | auto | system`
    - `queuePolicy: AgentQueuePolicy`
    - `visibilityPolicy: AgentVisibilityPolicy`
    - `submittedAt: Date`

4. `AgentTaskState` (extend current `AgentRunState`)
    - `owner`
    - `phase`
    - `statusText`
    - `progress`
    - `activeToken` (generation token for stale-event rejection)
    - `updatedAt`
    - `terminalReason` (optional)

5. `AgentQueuePolicy` (new)
    - `concurrentLimitPerKind: Int` (current baseline: `1`)
    - `waitingCapacityPerKind: Int` (current baseline: `1`)
    - `replacementWhenFull: latestOnlyReplaceWaiting | rejectNew`
    - Optional future extension (not MVP requirement): visibility-aware drop strategies

6. `AgentVisibilityPolicy` (new)
    - `selectedEntryOnly`
    - `always`

Mapping rule:

- Summary and translation must both map into this same schema.
- Persistent records (summary/translation outputs) stay feature-specific, but runtime lifecycle model is shared.

Identity and queue baseline (authoritative):

- `taskId` is the only unique identity of one submitted task instance.
- `owner` is entry/slot semantic binding for projection and scheduling scope, not unique identity.
- Concurrent active limit is scoped by `taskKind`, with current baseline `1` per kind.
- Waiting queue capacity is scoped by `taskKind`, with current baseline `1` per kind.
- Promotion is strictly within the same `taskKind`; cross-kind promotion is forbidden.

### 9.4 Queue Manager Standard Event Protocol (Step 2 Core Deliverable)

Add standardized runtime events (engine-level):

```swift
enum AgentRuntimeEvent {
     case queued(taskId: UUID, owner: AgentRunOwner, position: Int)
     case activated(taskId: UUID, owner: AgentRunOwner, activeToken: String)
     case phaseChanged(taskId: UUID, owner: AgentRunOwner, phase: AgentRunPhase)
     case progressUpdated(taskId: UUID, owner: AgentRunOwner, progress: AgentRunProgress)
     case terminal(taskId: UUID, owner: AgentRunOwner, phase: AgentRunPhase, reason: AgentFailureReason?)
     case promoted(from: AgentRunOwner, to: AgentRunOwner?)
     case dropped(taskId: UUID, owner: AgentRunOwner, reason: String)
}
```

Runtime API target shape:

- `submit(spec:) -> AgentRunRequestDecision`
- `updatePhase(owner:phase:...)`
- `finish(owner:terminalPhase:...) -> PromotionResult`
- `abandonWaiting(...)`
- `snapshot() -> AgentRunSnapshot`
- `events() -> AsyncStream<AgentRuntimeEvent>`

Contract rules:

1. All scheduling decisions come only from runtime engine.
2. `finish -> promote -> activate` is one actor transaction.
3. Events must be emitted in deterministic order within that transaction.
4. Any event with stale `activeToken` is ignored by projection consumers.
5. Event order guarantee is produced by runtime transaction semantics; UI is a passive consumer and must not re-schedule or reorder lifecycle.
6. Promotion candidate selection is same-kind only (`summary -> summary`, `translation -> translation`).

### 9.5 File-Level Implementation Blueprint (Function-Level)

This section defines the first implementation cut by file and function scope.

#### 1) `Mercury/Mercury/AgentRunCore.swift`

Add or extend:

- `AgentTaskID` type alias/struct
- `AgentTaskSpec`
- `AgentQueuePolicy`
- `AgentVisibilityPolicy`
- `AgentTaskState` extension fields (`activeToken`, `terminalReason`)

No view coupling allowed in this file.

#### 2) `Mercury/Mercury/AgentRuntimeStore.swift`

Add storage for:

- `specByOwner` (or `specByTaskId`)
- active token tracking per active owner/task

Add helper functions:

- `upsertSpec(...)`
- `setActiveToken(...)`
- `activeToken(for:)`
- `removeTask(...)` (single cleanup primitive)

#### 3) `Mercury/Mercury/AgentRuntimeEngine.swift`

Add/modify:

- `submit(spec:)`
- `events()` stream source and event emitter internals
- promotion result payload (`promotedOwner`, `droppedOwners`, etc.)
- atomic terminal->promotion sequence

Guarantee:

- no caller outside runtime decides promoted next owner.

#### 4) `Mercury/Mercury/AgentRuntimeProjection.swift`

Add projection reducer APIs:

- `reduce(event:into:)`
- `visibleProjection(for:selectedEntryId:)`
- stale-token guard utility

Projection output must support both summary and translation uniformly.

#### 5) `Mercury/Mercury/AppModel+SummaryExecution.swift`

Refactor to:

- build `AgentTaskSpec` and call runtime `submit`
- send phase/progress/terminal updates only
- remove any local promotion ownership logic

#### 6) `Mercury/Mercury/AppModel+TranslationExecution.swift`

Same contract as summary execution path.

#### 7) `Mercury/Mercury/Views/ReaderDetailView.swift`

Phase-by-phase migration:

- remove view-owned promotion handlers:
  - `processPromotedSummaryOwner`
  - `processPromotedTranslationOwner`
  - `finishRunAndProcessPromoted` usage as scheduler hook
- remove view-owned pending truth maps as scheduler source:
  - `summaryPendingRunTriggers` (scheduler role)
  - `translationPendingRunRequests` (scheduler role)
- keep temporary UI cache fields only if they are pure render caches.
- subscribe to runtime projection stream and render by selected entry scope.

#### 8) Tests

- `Mercury/MercuryTest/AgentDisplayProjectionTests.swift`:
  - migrate toward runtime event reducer tests.
- add engine tests:
  - terminal->promotion determinism
  - stale token rejection
  - queue policy behavior

### 9.6 Step 1 + Step 2 Minimum Deliverable Patch Scope (MVP)

This is the smallest acceptable patch range before feature migration:

#### Included in MVP

1. Runtime data model unification (`AgentTaskSpec`, policy enums, token field).
2. Runtime event protocol + `AsyncStream` publisher from engine.
3. Engine submit/finish path emits standardized events.
4. No behavior change in summary/translation executors yet.
5. `ReaderDetailView` still works with existing paths (compat mode), but event stream is available.

#### Explicitly excluded from MVP

1. Full view subscription migration.
2. Deleting all legacy view-local pending maps.
3. Queue policy plugin adoption by summary/translation.

Reason:

- Keep first patch bounded and reviewable while establishing non-negotiable runtime contracts.

### 9.7 Race and Consistency Guarantees

Mandatory guarantees for all later phases:

1. Single transition authority: only runtime engine mutates lifecycle truth.
2. Token-based stale event rejection: no old run event may overwrite new active run.
3. Idempotent terminal handling: repeated terminal callbacks are safe.
4. Visibility gate in projection layer: non-selected entry tasks do not mutate selected-entry visible status.
5. Promotion atomicity: no gap where finished task is gone but promoted task has no activation event.
6. Event ordering authority: lifecycle order is guaranteed by runtime engine/state machine, not by view-level heuristics.

### 9.8 Review Checklist (for PR and Design Review)

Reviewers must verify:

1. No new view-level scheduling truth is introduced.
2. Runtime event protocol is complete and deterministic.
3. Data model fields are sufficient for future concurrency-limit increase.
4. Summary and translation are both representable without model divergence.
5. Step 1+2 patch is additive and backward-compatible.

### 9.9 Execution Sequence after MVP

After Step 1+2 MVP merges:

1. Migrate translation to runtime projection subscription (highest risk path first).
2. Migrate summary with policy adapter integration.
3. Remove legacy view scheduling logic and compatibility branches.
4. Raise queue limits in controlled experiments only after invariant tests pass.

### 9.10 Execution Plan (Review Baseline Before Implementation)

This section defines the implementation sequence to execute after design review approval.

Execution status snapshot (2026-02-21):

- Step 0: completed.
- Step 1: completed.
- Step 2: completed.
- Step 3: corrected to include owner-gated projection and owner-carried status mapping; completed only after this correction.
- Step 4: completed. Summary path now uses event-driven promotion via `observeRuntimeEventsForSummary` / `handleSummaryRuntimeEvent` / `activatePromotedSummaryRun`, mirroring the translation pattern. `processPromotedSummaryOwner` and `finishRunAndProcessPromoted` removed.
- Step 5: pending.
- Step 6: in progress (core invariants partially covered).

Step 0 — Contract freeze (no behavior changes)

1. Freeze section 9 contracts as authoritative source.
2. Freeze queue baseline: concurrent active limit `1` and waiting capacity `1` per `taskKind`.
3. Freeze promotion rule: same-kind only.

Acceptance:

- Team confirms no view-level lifecycle truth is allowed moving forward.

Step 1 — Runtime model patch (MVP part A)

1. Add/extend `AgentTaskSpec`, `AgentTaskState`, and queue policy fields in `AgentRunCore.swift`.
2. Ensure `taskId` vs `owner` semantics are documented in code comments and tests.

Acceptance:

- Build is green.
- Runtime model can represent both summary and translation without feature forks.

Step 2 — Runtime event protocol patch (MVP part B)

1. Implement standardized runtime event stream in `AgentRuntimeEngine.swift`.
2. Ensure deterministic event emission for `finish -> promote -> activate` transaction.
3. Keep compatibility mode for existing view path.

Acceptance:

- Engine emits complete event sequence for queue/activation/terminal/promoted/dropped flows.
- No behavior regression in current UI path.

Step 3 — Translation path migration (highest risk first)

1. Route translation submit/phase/progress/terminal through runtime APIs only.
2. Remove translation view-side scheduler hooks and local queue truth.
3. Keep UI as projection consumer + intent emitter only.

Acceptance:

- Repro scenario: A finishes and waiting B starts with correct visible feedback.
- No cross-entry contamination in translation projection.
- `owner.entryId == displayedEntryId` ownership gate is enforced by shared policy path before any translation projection update.

Step 4 — Summary path migration

1. Apply the same runtime-only lifecycle path to summary.
2. Keep summary-specific persistence and rendering adapters only.

Acceptance:

- Summary behavior matches current product contracts (including existing auto-run constraints).

Step 5 — Legacy scheduler removal

1. Delete view-owned promotion and waiting-truth scheduling code.
2. Remove compatibility branches after both feature migrations are stable.
3. Perform orphan cleanup for transition leftovers (dead hooks, dead pending caches, dead helper wrappers), preferably together with Phase 6 split PRs.

Acceptance:

- No remaining lifecycle scheduling entry points outside runtime engine.

Step 6 — Invariant tests and controlled scaling

1. Add/upgrade invariant tests:
    - terminal/promote/activate deterministic sequence
    - stale token rejection
    - same-kind-only promotion
    - concurrent limit per kind (`1` baseline)
    - queue capacity per kind (`1` baseline)
2. Only after all invariants pass, run controlled queue-capacity experiments (`2`, `3`) behind explicit config.

Acceptance:

- Invariant suite passes consistently.
- Any capacity increase is explicit and test-covered.
