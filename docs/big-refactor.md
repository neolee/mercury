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

35. `AppModel+SummaryRuntime.swift`  
    - Source: rename/merge from `AppModel+AISummaryExecution.swift` + `AppModel+AISummaryStorage.swift`.

36. `AppModel+TranslationRuntime.swift`  
    - Source: rename/merge from `AppModel+AITranslationExecution.swift` + `AppModel+AITranslationStorage.swift`.

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
2. Runtime migration risk: preserve current queue limits (`summary=1`, `translation=1`) during migration.
3. UI drift risk: lock user-visible status wording in projection tests.
4. Data safety risk: do not change storage schema while doing naming/runtime unification; schema changes are separate tasks.
5. Concurrency isolation risk: under compiler `default-isolation=MainActor`, runtime/value modules used by actors must explicitly declare `nonisolated` for pure value types and static policy/projection utilities.

---

## 8. Immediate Next Actions

1. Execute Phase 1 rename pass as a dedicated PR batch.
2. Execute Phase 2 cleanup (remove test-only wrappers).
3. Start Phase 3 runtime engine extraction with translation path first (highest current bug impact).
4. Continue Phase 4 by migrating view-side status/message assembly into `AgentRuntimeProjection` helpers.
