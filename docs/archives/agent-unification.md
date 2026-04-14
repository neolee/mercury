# Agent Unification Plan

> Date: 2026-03-06
> Status: Completed
> Scope: Summary, Translation, single-entry Tagging, and Batch Tagging user-facing execution flow

This document consolidates the recent analysis on batch-sheet string ownership and cross-agent execution inconsistencies.
It does not aim for a minimal-risk incremental cleanup.
Instead, it defines a more complete unification target so the codebase can converge on one coherent user-facing execution model, and any later rollback can be judged against a clear end state.

---

## 1. Goals

- Unify how all four agent tasks surface notices, failures, task titles, and progress text.
- Unify semantics first, while allowing the visual host surface to differ by task.
- Keep view-local copy local, but move reusable semantic projections out of individual views.
- Remove raw user-visible string construction from execution and persistence layers.
- Make single-entry Tagging follow the same presentation discipline already used by Summary, Translation, and the newer Batch Tagging refactor.
- Eliminate duplicated fallback/failure wording so localization and behavior cannot drift by task.

## 1.1 Confirmed decisions

The following decisions are now confirmed and should be treated as implementation inputs rather than open questions.

- Summary, Translation, and single-entry Tagging are all entry-bound tasks and may use the Reader top banner as a valid projected-message host.
- Batch Tagging must not use the Reader top banner. It must use a fixed projection area inside the batch sheet for notices, failures, and optional actions during the batch lifecycle.
- Shared message semantics must be independent from host surface choice.
- Shared message projection must be reused even when the final visual carrier differs by task.
- Shared facilities must be mandatory for agent-task presentation concerns. New task-specific re-implementations are not acceptable when an approved shared facility already exists.
- Reader-banner arbitration uses these confirmed priorities: non-current-entry messages are dropped; user-initiated task messages outrank automatic/background task messages; messages with actions outrank messages without actions; otherwise newer messages replace older ones.
- Batch Tagging uses the empty area in the bottom action row between the left-side negative action and the right-side action group as its fixed projected-message host.
- Structured message composition is the default direction, but if a step would require a broad high-risk multi-file patch only to satisfy composition purity, that step must be raised for explicit discussion before implementation.

## 1.2 Confirmed implementation guardrails

All blocking policy decisions have now been confirmed.
This section records the guardrails that must constrain implementation.

### 1.2.1 Typed notice policy

This policy is confirmed.

The adopted implementation does not introduce one cross-agent notice enum.
Instead, each task keeps a small typed notice enum and shared projection converts those typed notices into one projected-message contract.

Practical interpretation:

- do not use raw `notice(String)` payloads for reusable app-authored notices;
- keep task-local notice enums small and semantic;
- route shared semantics such as prompt-template fallback through shared projection/helpers rather than re-authoring strings in execution code;
- if a future requirement genuinely needs externally supplied freeform text, treat that as a separate design decision rather than a default path.

### 1.2.2 Structured message composition policy

This direction is confirmed.

Confirmed default:

- do not concatenate arbitrary notice and failure strings in views;
- produce a structured projection result with fields such as primary text, secondary text, primary action, secondary action, severity, and host;
- let the host renderer decide layout, not semantics.
- if a specific step requires a large, high-risk, cross-file patch just to satisfy composition purity, stop and discuss whether the churn is necessary and worth it.

### 1.2.3 Batch sheet projection-slot form

This decision is confirmed.

Confirmed form:

- keep it sheet-native in layout, but functionally equivalent to the Reader banner contract;
- use the blank area in the bottom action row between the left-side negative action and the right-side action group;
- supports severity styling and optional actions;
- no modal takeover for non-fatal notices or normal terminal failures.

---

## 2. Ownership Rules for User-Visible Strings

The correct boundary is not “all strings must be shared” and not “every view owns everything”.
The right split is semantic reuse vs sheet-local UX text.

## 2.1 Strings that should stay local to the view

These strings are part of a specific screen layout or interaction contract and should remain owned by the view that renders them.

- Sheet titles and section headers.
- Button labels tied to one surface layout.
- Confirmation dialog copy.
- Guidance paragraphs that only make sense in one screen.
- Completion summary sentences that summarize one screen-specific workflow.
- Empty-state phrasing that depends on the local composition of the UI.

For Batch Tagging, this means the following categories should remain in `BatchTaggingSheetView` or a batch-sheet-local presentation helper:

- sheet title, footer button labels, and review/apply guidance;
- destructive confirmation copy (`Abort`, `Reset`, discard confirmation, large-batch warning wording if it remains sheet-specific);
- completion summary text that combines batch-specific counters into one paragraph;
- local layout labels such as section captions and inline helper text.

## 2.2 Strings that should reuse shared projection or helper logic

These strings represent reusable semantics, not one-screen wording.
They should come from a shared projection/helper layer even if each view still decides where to place them.

- Prompt-template fallback notices.
- Failure reason to user-message projection.
- Task display titles.
- Task-status display labels when the status concept is shared.
- Scope labels when the same scope can appear in multiple surfaces.
- Shared phase labels if multiple tasks expose equivalent execution phases.
- Notice text for reusable notice kinds.

For the current codebase, the best immediate shared candidates are:

- `AgentPromptCustomizationConfig.invalidTemplateFallbackMessage(bundle:)` style prompt-fallback copy.
- `AgentRuntimeProjection.failureMessage(for:taskKind:)` and related banner projection.
- `AppTaskKind.displayTitle` as the single source of task names.
- A future shared projection for batch scope labels and batch status labels if they will appear outside the sheet.
- A future shared projection for typed user notices across all agent tasks.

## 2.3 Boundary rule

Execution/runtime/store layers may emit typed semantic events.
They should not emit already-final user text except where the domain is explicitly “freeform model output”.

Views may compose screen-local sentences from typed state.
Views should not re-implement reusable domain-to-message mapping that already exists elsewhere.

The visual host that carries the projected message is a separate concern.
It should be configurable per task instead of being hard-coded into the message semantics.

---

## 3. Current Inconsistencies Across the Four Agent Tasks

The codebase currently has four partially similar but still divergent user-facing execution paths.

## 3.1 Notice channel inconsistency

Current state:

- Batch Tagging already uses a typed notice path.
- Summary, Translation, and single-entry Tagging still use `notice(String)`.

Why this is a problem:

- raw notice strings force execution code to own phrasing too early;
- shared fallback and status notices cannot be reused safely;
- UI tests become string-shape tests instead of semantic tests;
- localization drift becomes likely when the same semantic event is rephrased in multiple features.

Recommended solution:

- Replace all string notice channels with typed notice enums.
- Keep shared semantics aligned in the projection layer instead of requiring one cross-task notice enum.

## 3.2 Failure projection inconsistency

Current state:

- Summary and Translation already reuse more of the shared failure projection path.
- Batch Tagging was aligned recently.
- single-entry Tagging still lags in how it surfaces terminal failures and notices.

Why this is a problem:

- identical failures can produce different wording by task;
- the UI cannot rely on one projection policy;
- changes to failure semantics require touching multiple views.

Recommended solution:

- Route all terminal user-facing failure copy through shared projection.
- Keep task-specific specialization in the shared projection layer, not in individual views.

## 3.3 Task presentation inconsistency

Current state:

- older execution paths still construct task titles and progress strings directly in execution code;
- Batch Tagging already removed some execution-layer progress phrasing.

Why this is a problem:

- progress copy leaks into orchestration code;
- task names can drift from UI labels;
- refactoring localization becomes harder because strings are scattered through execution paths.

Recommended solution:

- Centralize task display title ownership on `AppTaskKind`.
- Centralize progress/phase presentation on a shared presentation layer rather than per-executor ad-hoc strings.

## 3.4 Runtime integration inconsistency

Current state:

- Summary and Translation are closer to the shared runtime projection model.
- single-entry Tagging still behaves more like a feature-specific panel flow.
- Batch Tagging uses the task infrastructure but not the same UI consumption shape as the reader agents.

Why this is a problem:

- the app now has two and a half interaction models instead of one;
- future features will copy whichever pattern is closest, increasing divergence;
- testing the same concepts requires task-specific fixtures and assertions.

Recommended solution:

- Keep Batch Tagging as a separate workflow surface, but align its user-facing semantics with the same typed notice, terminal outcome, and task presentation rules.
- Keep Summary, Translation, and single-entry Tagging on the Reader-area interaction model because they are directly tied to the currently displayed entry content.
- Pull single-entry Tagging closer to the runtime projection discipline already used by Summary and Translation without removing its use of the Reader-area banner host.

## 3.5 Prompt fallback propagation inconsistency

Current state:

- shared prompt-fallback wording now exists and is reused in the batch path;
- however the overall pattern is still uneven because older tasks still treat notices as raw strings.

Why this is a problem:

- one shared fallback message exists, but the surrounding event model is still divergent;
- future prompt-related notices will likely fork again unless the notice channel is unified.

Recommended solution:

- treat prompt fallback as one typed notice kind in the shared notice system;
- let each surface decide placement and timing, but not wording.

---

## 4. Target End State

The desired end state is one presentation contract used by all four tasks.

## 4.0 Shared semantics, parameterized host surfaces

The most important clarification is that semantic unification does not require one identical visual carrier.

The intended model is:

- one shared projected-message contract;
- one shared projected-message result shape;
- one shared projection layer for reusable wording;
- a task-specific presentation policy that decides where the projected message appears.

The host-surface policy should be:

- Summary: Reader top banner remains a valid host because summary execution is directly about the currently displayed entry.
- Translation: Reader top banner remains a valid host because translation state and retry/resume actions are directly tied to the current entry.
- single-entry Tagging: Reader top banner remains a valid host because the tagging panel is editing tags for the current entry only.
- Batch Tagging: never use the Reader top banner; use a fixed projection area inside the batch sheet because the workflow is independent of the current Reader entry.

This means the unification work should separate:

- message meaning;
- projected message structure;
- message text projection;
- message host placement;
- optional actions associated with the message.

## 4.0.1 Presentation policy contract

Introduce a small shared policy model that tells each task how projected messages are hosted.

For example:

```swift
enum AgentMessageHost: Sendable, Equatable {
    case readerTopBanner
    case inlinePanelStatus
    case batchSheetBannerSlot
    case modalAlert
}

struct AgentTaskPresentationPolicy: Sendable, Equatable {
    let taskKind: AppTaskKind
    let primaryMessageHost: AgentMessageHost
    let allowsInlineNoticeDuringRun: Bool
    let allowsTerminalBanner: Bool
    let allowsActionLinks: Bool
}
```

The exact API shape can vary, but the contract should make host choice explicit and centralized.

The shared presentation layer should also define a structured projected-message shape, for example:

```swift
struct AgentProjectedMessage: Sendable, Equatable {
    let primaryText: String
    let secondaryText: String?
    let severity: AgentMessageSeverity
    let primaryAction: AgentProjectedMessageAction?
    let secondaryAction: AgentProjectedMessageAction?
    let host: AgentMessageHost
}
```

The exact fields can vary, but the important rule is that composition happens before host rendering.

## 4.0.2 Fixed decisions

The following should now be treated as fixed rather than open:

- Reader top banner is a legitimate host for Summary, Translation, and single-entry Tagging.
- Batch Tagging must use its own sheet-local projection area rather than any Reader-area banner.
- Shared semantics and shared wording must not depend on which host surface is selected.
- A task may support actions on the projected message, and those actions should also be described structurally rather than built ad hoc in each view.
- When a shared presentation facility exists for an agent-task concern, task-specific code must call into that facility instead of forking a parallel implementation.

## 4.1 Typed notices with shared projection

The adopted shape is:

- each task emits typed notices using its own small notice enum;
- shared semantics are aligned by projection, not by forcing all tasks into one shared enum;
- the shared contract consumed by hosts is `AgentProjectedMessage`, not a single cross-task notice type.

This keeps execution events strongly typed while avoiding an extra wrapper layer that would mostly mirror task-local enums.

## 4.2 Shared notice-to-text projection

Introduce one projection/helper to convert typed notices into localized text.

Example responsibility split:

- execution layer: emits `.promptTemplateFallback` on the task-local notice enum;
- UI or shared projection layer: converts it to the localized fallback string;
- presentation policy: decides whether it goes to Reader banner, inline panel status, batch sheet fixed slot, or another approved host.
- view: renders the already projected message in the host selected by policy.

This keeps placement local while keeping meaning shared.

The same rule applies to message actions and severity styling: shared semantics first, host rendering second.

## 4.3 Shared terminal outcome projection

All terminal failure and completion messaging should flow through shared projection rules.

Target rules:

- `AgentFailureReason` stays the main shared failure-semantic type;
- `AgentRuntimeProjection` owns user-facing failure/banner wording;
- task-specific specialization is allowed, but only inside the shared projection layer;
- views do not switch over low-level failure reasons to produce their own English strings.

Batch Tagging may still render the projected failure inside a fixed sheet-local status area instead of a Reader banner.

## 4.4 Shared task presentation model

Introduce a shared presentation layer for titles, phase text, and optional progress copy.

Suggested responsibilities:

- `AppTaskKind.displayTitle` remains the source of task names;
- a new shared presentation helper owns reusable phase labels;
- execution code reports state/progress structurally rather than as fully phrased strings whenever possible.

This does not require every task to expose the same phases.
It requires equivalent concepts to be rendered from one semantic source instead of from scattered ad-hoc strings.

This shared presentation model should also own host-surface configuration rather than burying it inside each view.

It should also own banner arbitration policy for Reader-bound tasks, so conflict handling is centralized rather than view-specific.

## 4.5 Single-entry Tagging alignment

single-entry Tagging should no longer remain the exception.

It should align with Summary and Translation on:

- typed notices;
- shared terminal failure projection;
- centralized task display title;
- reduced execution-layer ownership of progress text.

This is the most important feedback path from the new Batch Tagging cleanup into the older agent tasks.

## 4.6 Batch-specific semantics remain batch-specific

Unification does not mean flattening Batch Tagging into the reader-agent UI model.

Batch Tagging should still keep:

- its own sheet lifecycle;
- its own review/apply workflow;
- its own configure/running/review/applying/done state model.

What should be shared is the semantic language around notices, failures, titles, and reusable labels.

What may remain different is the screen region that carries those projections.

---

## 5. Concrete Execution Strategy

This section intentionally prefers a more complete unification pass instead of a narrowly conservative one.

## 5.1 Step 1: Introduce the shared message contracts

Create the shared projected-message result shape, shared notice/failure projection helper, and shared host-surface policy contract.

Required actions:

- replace raw string notice payloads with typed task-local notice enums;
- define the shared projected-message result shape;
- add localized projection for each notice kind;
- define centralized host-surface policy for each task kind;
- define structured optional message actions so links/buttons are configured semantically instead of view-locally;
- define centralized severity and conflict-arbitration rules for Reader-banner-hosted tasks;
- make prompt-template fallback a typed notice case immediately.

Deliverable:

- one projected-message model and one host policy model that can be consumed by Summary, Translation, Tagging, and Batch Tagging, with reusable notices emitted as typed task-local events.

## 5.2 Step 2: Build shared host rendering adapters

Before migrating individual tasks, establish the shared rendering adapters for the two approved hosts.

Required actions:

- add the Reader-banner adapter that renders a projected message according to the shared host policy;
- add the batch-sheet footer adapter that renders a projected message in the fixed middle area of the bottom action row;
- implement centralized Reader-banner arbitration using the confirmed priorities;
- keep surface-specific layout details local while removing surface-specific message semantics.

Deliverable:

- both approved hosts can render the same projected-message contract before task-by-task migration begins.

## 5.3 Step 3: Migrate Summary and Translation first

Summary and Translation are already closest to the shared runtime projection model, so they are the cleanest first adopters.

Required actions:

- change `SummaryRunEvent.notice(String)` to typed notice;
- change `TranslationRunEvent.notice(String)` to typed notice;
- remove any remaining direct fallback-message construction from those execution paths;
- keep Reader top banner as a supported host surface while replacing the data shape underneath;
- route banner actions through the shared message-action contract rather than ad-hoc per-view construction where practical.

Deliverable:

- Summary and Translation consume typed notices end-to-end.

## 5.4 Step 4: Align single-entry Tagging to the same model

single-entry Tagging should be upgraded next, not deferred.

Required actions:

- replace `TaggingPanelEvent.notice(String)` with typed notice;
- route terminal failure rendering through shared projection only;
- remove panel-local duplication of failure wording if any remains;
- centralize tagging task title ownership on `AppTaskKind.displayTitle`.
- keep Reader top banner as the primary projected-message host for tagging-related warnings/errors tied to the current entry.

Deliverable:

- Tagging no longer behaves like an architectural outlier.

## 5.5 Step 5: Centralize task titles and progress presentation

Before rebasing Batch notices, stabilize the remaining shared presentation vocabulary.
This reduces churn because Batch should consume the same final task-title, phase-label, and progress semantics rather than being migrated twice.

Required actions:

- verify all task titles come from `AppTaskKind.displayTitle`;
- introduce a shared presentation helper for task phases or progress labels;
- replace hard-coded phrases such as “Preparing summary”, “Preparing translation”, and “Preparing tag suggestions” with structured phase reporting plus shared projection;
- keep views free to omit phase text when the local UI does not need it.

Deliverable:

- execution code stops owning localized progress prose.

## 5.6 Step 6: Unify failure and banner policy completely

The app should have one rule for user-facing terminal messaging.

Required actions:

- audit all four task UIs for hand-written failure switches;
- move remaining reusable wording into shared projection;
- define one structured policy for how notice, failure, and optional actions are combined or prioritized before projection;
- ensure Tagging and Batch Tagging follow the same projection discipline as Summary and Translation, even when their host surfaces differ.
- ensure Reader-banner arbitration for Summary / Translation / Tagging is implemented in one shared policy layer.

Deliverable:

- one failure/message projection policy across all four tasks, with host-surface choice treated as a parameter rather than a semantic difference.

## 5.7 Step 7: Rebase Batch Tagging onto the shared projection contract

Batch Tagging should move after shared projection rules are stable, not before.
In practice, the batch path depends on the final shared rules for notice wording, failure projection, task titles, and optional actions.
Rebasing earlier creates avoidable rework because the batch sheet would first adopt an intermediate contract and then be reshaped again.

Required actions:

- keep `TagBatchRunNotice` for batch-local lifecycle semantics;
- reuse shared projection helpers for shared semantics such as prompt-template fallback and terminal failures;
- keep batch-only notice cases for review/apply-specific semantics;
- move any newly shared notice wording into the shared projection helper.
- map projected messages into one fixed, always-available status slot inside the batch sheet instead of using the Reader banner host.

Preferred direction:

- keep task-local typed notices and route them through the shared projection layer.
- reserve batch-local notice cases only for truly batch-exclusive workflow messages.
- make the batch-sheet projection slot structurally explicit so it serves the same semantic role as the Reader banner for the other tasks.

Deliverable:

- Batch Tagging remains workflow-distinct but no longer vocabulary-distinct for shared events.

## 5.8 Step 8: Share reusable labels beyond notices and failures

Once the main message pipeline is unified, promote repeated labels that are clearly semantic.

Candidates:

- batch scope display names;
- batch status display names;
- reusable action labels if they are no longer surface-specific;
- reusable completion-state wording where multiple task surfaces converge.

Rule:

- only promote labels that clearly describe shared semantics;
- keep composition-heavy sentences in the local view.

Deliverable:

- remaining duplication is intentional rather than accidental.

## 5.9 Step 9: Remove dead interfaces and legacy compatibility shims

Final cleanup should remove migration leftovers, but only where the caller graph proves the bridge is no longer needed.

Completed outcomes:

- obsolete `notice(String)` variants across Summary, Translation, single-entry Tagging, and Batch Tagging are gone;
- dead local batch status/scope label switches were replaced by shared semantic helpers where reuse existed;
- reusable action labels now come from shared projection helpers rather than duplicated surface-local literals;
- documentation now describes the unified presentation contract instead of an in-progress migration.

Retained intentionally:

- the Reader host still stores `ReaderBannerMessage` as its local view state, so the bridge between projected messages and the legacy reader banner model remains a required adapter rather than dead compatibility code.

Deliverable:

- the architecture is actually unified, not just layered with adapters.

---

## 6. File-Level Impact Map

The main implementation wave is expected to touch at least these areas:

- `Mercury/Mercury/Agent/Shared/AgentPromptCustomization.swift`
- `Mercury/Mercury/Agent/Runtime/AgentRuntimeProjection.swift`
- `Mercury/Mercury/Core/Tasking/AppTaskContracts.swift`
- `Mercury/Mercury/Agent/Summary/AppModel+SummaryExecution.swift`
- `Mercury/Mercury/Agent/Translation/AppModel+TranslationExecution.swift`
- `Mercury/Mercury/Agent/Tagging/AppModel+TagExecution.swift`
- `Mercury/Mercury/Agent/Tagging/AppModel+TagBatchExecution.swift`
- `Mercury/Mercury/App/Views/ReaderSummaryView+Runtime.swift`
- `Mercury/Mercury/App/Views/ReaderTranslationView+RunLifecycle.swift`
- `Mercury/Mercury/App/Views/ReaderTaggingPanelView.swift`
- `Mercury/Mercury/App/Views/BatchTaggingSheetViewModel.swift`
- `Mercury/Mercury/App/Views/BatchTaggingSheetView.swift`

Likely test areas:

- notice/event stream tests for each task;
- shared failure projection tests;
- prompt fallback notice tests;
- task-title/progress presentation tests if a new projection helper is introduced.

---

## 7. Acceptance Criteria

The unification work should be considered complete only when all of the following are true.

- No execution path among the four tasks uses `notice(String)` as its primary notice contract.
- Prompt fallback wording comes from one shared helper/projection path.
- Terminal failure wording comes from one shared projection policy.
- Task titles are centrally owned and no longer hard-coded per executor.
- The host surface for each task is centrally defined rather than implied by view-local branching.
- Summary, Translation, and single-entry Tagging keep Reader top banner support without reintroducing task-specific message semantics.
- Batch Tagging uses a fixed sheet-local projection area with the same semantic projection contract.
- Reader-banner conflict resolution is centrally defined and not re-implemented by each Reader task.
- The project has no new task-specific fallback/failure/presentation helpers that duplicate an approved shared facility.
- Typed task-local notices are allowed; a single cross-task notice enum is not required.
- Reusable semantic labels are not duplicated across views.
- View-local strings that remain local are clearly screen-specific, not accidental re-implementations of shared semantics.
- Tests validate semantics, not repeated ad-hoc user strings in multiple places.

---

## 8. Recommended Execution Order

If this plan is executed as one sustained cleanup wave, the best order is:

1. Shared message contracts.
2. Shared Reader-banner and batch-footer host adapters.
3. Summary migration.
4. Translation migration.
5. single-entry Tagging migration.
6. Shared task title and phase/progress presentation cleanup.
7. Final failure/banner policy audit.
8. Batch Tagging rebasing onto shared notice semantics after the shared projection rules are stable.
9. Removal of dead interfaces and documentation/test updates.

This order is preferable because it separates two kinds of work that were previously interleaved:

- first stabilize shared semantics and shared projection rules;
- then migrate the batch-specific event model onto those now-stable rules.

In other words, Batch Tagging is now treated as a downstream consumer of the shared presentation contract, not as a place where that contract is still being discovered.

---

## 9. Non-Goals

This plan does not require:

- collapsing Batch Tagging into the reader runtime UI model;
- forcing all tasks to expose identical UI states;
- removing view-local UX copy that is legitimately local;
- redesigning persistence schemas unrelated to user-facing execution messaging.

The goal is not visual sameness.
The goal is one coherent semantic contract behind different surfaces.
