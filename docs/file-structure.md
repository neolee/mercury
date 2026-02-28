# Mercury File Structure Refactoring Plan

## Context and Goals

This document defines a target file structure for the `Mercury/Mercury` module and a migration plan for current oversized files.

Primary goals:

1. Make directory ownership clear and stable.
2. Keep file counts per directory reasonable.
3. Split oversized files into smaller files with explicit responsibility boundaries.
4. Preserve behavior while refactoring (structure-first, logic-stable).

---

## Organizing Principle

Use **feature-first** structure as the primary axis, and **responsibility layer** as a secondary axis inside each feature.

Additional constraint:

1. Do not create directories deeper than **two levels under `Mercury/Mercury`**.
2. If a directory becomes crowded, prefer splitting files by prefix/responsibility before introducing a third nesting level.

Why this is preferred over pure `Model/View`:

1. Current complexity is dominated by feature domains (`Reader`, `Agent`, `Translation`, `Usage`) rather than UI vs data.
2. Pure `Model/View` would still create overloaded directories.
3. Feature-first keeps related runtime, storage, contracts, and views close to each other.

---

## Target Directory Layout

```text
Mercury/Mercury
  App/
    Views/
  Core/
    Database/
    Tasking/
    Shared/
    Views/
  Reader/
    Views/
    Theme/
  Agent/
    Runtime/
    Provider/
    Summary/
    Translation/
    Settings/
    Shared/
  Feed/
    UseCases/
    Sync/
    ImportExport/
    Views/
  Usage/
    Views/
  Resources/
  Views/   (temporary during migration; target is to remove or keep very thin wrappers)
```

Why this flatter layout:

1. Remove the extra `Features/` wrapper to keep paths short and scanning cost low.
2. Make the first path segment directly express ownership (`Reader`, `Agent`, `Feed`, `Usage`).
3. Keep room for one responsibility layer without crossing the two-level limit.

---

## Directory Contract and Placement Criteria

### `App/`

Purpose:

1. App entry point and root composition.
2. App-level dependency wiring.
3. Global environment and app lifecycle glue.

Put files here when:

1. The file configures application startup, scenes, or root state wiring.
2. The file has no feature business logic and mostly coordinates modules.

Keep out:

1. Feature-specific runtime logic.
2. SQL, migration, and queue internals.

Typical files:

1. `MercuryApp.swift`
2. Root `ContentView` composition shell (if kept app-level).

### `App/Views/`

Purpose:

1. App-shell views and window-level composition.
2. Views that coordinate multiple feature panes at once.

Put files here when:

1. The view composes feed, reader, status, or settings areas into the main app shell.
2. The primary job is application-level layout, not one feature's business UI.

Keep out:

1. Feed-only list views.
2. Reader-only detail and toolbar views.
3. Agent settings or usage report screens with clear feature ownership.

Typical files:

1. `ContentView.swift`
2. `ContentView+Commands.swift`
3. `ContentView+EntryLoading.swift`
4. `ContentView+FeedActions.swift`
5. `ContentView+Status.swift`
6. `AppSettingsView.swift`
7. `DebugIssuesView.swift`

### `Core/Database/`

Purpose:

1. Database access primitives.
2. Migration infrastructure and migration sets.
3. Cross-feature persistence helpers.

Put files here when:

1. The file owns schema, migration registration, or DB configuration.
2. The file is persistence infrastructure reused by multiple features.

Keep out:

1. Feature-specific query orchestration that is only meaningful in one feature.

Typical files:

1. `DatabaseManager.swift` split pieces.
2. Migration files grouped by domain (`DatabaseMigrations+Feed`, `+Agent`, `+Usage`, `+Translation`).

### `Core/Tasking/`

Purpose:

1. App-wide queueing, timeout policy, task records.
2. Queue event stream and task center projection.

Put files here when:

1. The logic is generic task lifecycle behavior reused by multiple features.

Keep out:

1. Feature-specific terminal semantics and agent-only classification.

Typical files:

1. `TaskQueue.swift` split pieces.
2. `TaskLifecycleCore.swift`.

### `Core/Shared/`

Purpose:

1. Shared, feature-agnostic utilities and contracts.

Put files here when:

1. It is reused by at least two features.
2. The type name and API are domain-neutral.

Keep out:

1. Feature nouns in type/API names (`Summary`, `Translation`, `Reader`) unless truly shared by those features.

### `Core/Views/`

Purpose:

1. Reusable UI primitives that are not owned by one feature.

Put files here when:

1. The view is used by multiple features.
2. The view has no business semantics by itself and behaves as a generic control/helper.

Keep out:

1. Feature-branded screens.
2. Reader-only, feed-only, or usage-only views.

Typical files:

1. `SplitDivider.swift`
2. `ToolbarSearchField.swift`
3. `SettingsSliderRow.swift`

### `Reader/`

Purpose:

1. Reader-specific support types and feature-local helpers.
2. Reader domain files that are not large enough to justify their own subdirectory.

Put files here when:

1. The file is reader-specific but is neither a SwiftUI screen nor a theme definition.
2. The file supports rendering, reader state, or reader-specific transformations.

Typical files:

1. `Reader.swift`
2. `ReaderTypes.swift`
3. `Markdown.swift`
4. `AppModel+Reader.swift`

### `Reader/Views/`

Purpose:

1. Reader-facing SwiftUI views and view-only helpers.

Put files here when:

1. The file is a SwiftUI `View` for reader interactions.
2. The file mostly manages view state and rendering.

Keep out:

1. Persistence queries and model-provider routing.

Typical files:

1. `ReaderDetailView` and its extensions.
2. `ReaderSummaryView` split files.
3. `ReaderTranslationView` split files.

### `Reader/Theme/`

Purpose:

1. Theme domain types, rules, presets, and validation.

Put files here when:

1. The file defines reader theme contracts or theme transformation logic.

Keep out:

1. View layout code unrelated to theme semantics.

Typical files:

1. `ReaderThemeTypes.swift`
2. `ReaderThemeRules.swift`
3. `ReaderThemePreset.swift`
4. `ReaderThemeResolver.swift`

### `Agent/Runtime/`

Purpose:

1. Agent runtime state machine and runtime engine.
2. Run projection and in-memory runtime store.

Put files here when:

1. The file is runtime orchestration infrastructure for agent tasks.

### `Agent/Provider/`

Purpose:

1. LLM provider abstraction implementations and provider error mapping.

Put files here when:

1. The file handles network call contracts and provider endpoint routing.

Typical files:

1. `AgentLLMProvider` split files.
2. `AgentProviderValidation`.

### `Agent/Summary/`

Purpose:

1. Summary task contracts, execution, storage, and prompt customization.

Put files here when:

1. The file name or type clearly centers on summary behavior.

### `Agent/Translation/`

Purpose:

1. Translation task contracts, execution, storage, prompt customization, segmentation.

Put files here when:

1. The type names and APIs revolve around translation-specific semantics.

Typical files:

1. `AppModel+TranslationExecution` split files.
2. `AppModel+TranslationStorage` split files.
3. `Translation*` contract/helper files.

### `Agent/Settings/`

Purpose:

1. Agent settings defaults, provider/model profile CRUD, and connection tests.

Put files here when:

1. The logic is about configuration and settings mutation rather than run execution.

Typical files:

1. `AppModel+Agent` split files.
2. Agent settings views.

### `Agent/Shared/`

Purpose:

1. Shared helper logic used by summary and translation execution paths.

Put files here when:

1. The helper is agent-task specific but not tied to one task type.

Typical files:

1. `AgentExecutionShared` split files.
2. Failure classifier and shared terminal outcome helpers.

### `Feed/`

Purpose:

1. Feed-specific support types, policies, and feature-local services.
2. Files owned by the feed domain that do not need a deeper bucket.

Put files here when:

1. The file is feed-specific but is not primarily a view, import/export pipeline, or use-case unit.

Typical files:

1. `FeedInputValidator.swift`
2. `FeedTitleResolver.swift`
3. `MarkReadPolicy.swift`
4. `AppModel+Feed.swift`
5. `AppModel+Sync.swift`
6. `AppModel+ImportExport.swift`
7. `OPML.swift`

### `Feed/UseCases/`

Purpose:

1. Feed-oriented business use cases.

Put files here when:

1. The file defines one cohesive use case unit.

Rule:

1. One use case type per file.

### `Feed/Sync/`

Purpose:

1. Feed synchronization and related IO coordination.

Put files here when:

1. The primary behavior is sync operations and feed refresh lifecycle.

### `Feed/ImportExport/`

Purpose:

1. OPML and bootstrap import/export pipelines.

Put files here when:

1. The file manages import/export data flow and progress reporting.

### `Feed/Views/`

Purpose:

1. Feed browsing and navigation views.
2. Feed-scoped list UI, search UI, and feed editing/import sheets.

Put files here when:

1. The primary UI concern is feed selection, entry list browsing, or feed management.
2. The view mainly serves the feed list pane, entry list pane, or feed CRUD/import flow.

Keep out:

1. Reader detail pane views.
2. App-level shell/container composition that wires the whole window together.

Typical files:

1. `SidebarView.swift`
2. `EntryListView.swift`
3. `FeedEditorSheet.swift`
4. `ImportOPMLSheet.swift`
5. Feed-specific toolbar/search helpers if they are not reused elsewhere.

### `Usage/`

Purpose:

1. Usage report contracts, retention, and data/query logic.
2. Usage-specific non-view code.

Put files here when:

1. The file defines usage snapshots/contracts.
2. The file performs usage aggregation, retention, or report query assembly.

Typical files:

1. `UsageReportContracts.swift`
2. `AppModel+UsageReport.swift`
3. `AppModel+UsageRetention.swift`

### `Usage/Views/`

Purpose:

1. Usage report SwiftUI pages and chart tables.

Put files here when:

1. The file is a usage analytics screen or subview.

---

## Naming and File Size Rules

### Directory depth

1. Maximum nesting: two levels under `Mercury/Mercury`.
2. Allowed examples: `Reader/Views`, `Agent/Translation`, `Core/Database`.
3. Disallowed examples: `Features/Reader/Views`, `Agent/Translation/Views`, `Feed/ImportExport/OPML`.

### Naming

1. Keep existing prefixes (`Agent*`, `Summary*`, `Translation*`, `Reader*`) to preserve discoverability.
2. For split files, use `BaseName+Responsibility.swift` pattern.
3. One file should read as one responsibility in one sentence.

### File size guardrails

1. Domain type/contract files: target `<= 200` lines.
2. Use-case/service files: target `<= 300-350` lines.
3. SwiftUI main view files: target `<= 350-450` lines.
4. Any file above `500` lines requires explicit split rationale.

### Directory size guardrails

1. Target `<= 12-18` files per directory.
2. If a directory exceeds `20` files, first split oversized files.
3. If a directory still exceeds `20` files, add at most one second-level subdirectory under the top-level domain.
4. Do not solve crowding by adding a third-level directory.

---

## Split Principles

These principles override any earlier tendency to split files too aggressively.

### Size thresholds

1. Files under `500` lines are acceptable by default.
2. Files in the `500-1000` range require judgment, not automatic splitting.
3. Files over `1000` lines should be split for manageability, even if the module is still coherent.

### Cohesion first

1. If a file still represents one architecturally independent module, do not split it just to make the line count look cleaner.
2. Internal ordering, `MARK` grouping, and code locality are preferred over fragmentation when the module boundary is still clear.

### When splitting is justified

1. Split when a file contains multiple parallel modules or clearly separate sub-flows.
2. For `>1000` line files, split by function into a small number of peer files.
3. Prefer `extension`-based split files for one large type/module instead of extracting many tiny helper files.

### When splitting is not justified

1. Do not split a file only to make all files numerically similar.
2. Do not create one file per helper or one file per tiny concern inside an otherwise coherent module.
3. Do not create more sub-directories to compensate for over-splitting.

### Cross-group dependency review rule

1. `App` and `Core` are foundational layers; other groups depending on them is normal.
2. Cross-dependencies among `Reader`, `Agent`, `Feed`, and `Usage` need explicit review.
3. If a type is used broadly across those feature groups, either the boundary is wrong or the shared part should move into a more neutral shared layer.

---

## Oversized File Split Plan (Current Hotspots)

### `ReaderTranslationView.swift` (1802)

Status:

1. Must split because it is over `1000` lines.
2. Split at medium granularity, not helper-by-helper.

Target split:

1. `ReaderTranslationView.swift`
2. `ReaderTranslationView+Actions.swift`
3. `ReaderTranslationView+Projection.swift`
4. `ReaderTranslationView+Runtime.swift`

### `ReaderSummaryView.swift` (1301)

Status:

1. Must split because it is over `1000` lines.
2. Keep the split to a few peer files.

Target split:

1. `ReaderSummaryView.swift`
2. `ReaderSummaryView+Runtime.swift`
3. `ReaderSummaryView+AutoSummary.swift`
4. `ReaderSummaryView+Scroll.swift`

### `AppModel+TranslationExecution.swift` (1055)

Status:

1. Must split because it is over `1000` lines.
2. Keep contracts close to the module unless a shared boundary becomes clear.

Target split:

1. `AppModel+TranslationExecution.swift`
2. `AppModel+TranslationExecution+PerSegment.swift`
3. `AppModel+TranslationExecution+Request.swift`
4. `AppModel+TranslationExecution+Support.swift`

### `AppModel+UsageReport.swift` (828)

Status:

1. Keep as one file for now.
2. It is large but still coherent around one usage-report module.

### `UseCases.swift` (728)

Status:

1. Split now.
2. It contains multiple independent use cases, not one coherent module.

Target split:

1. `UnreadCountUseCase.swift`
2. `FeedCRUDUseCase.swift`
3. `ReaderBuildUseCase.swift`
4. `FeedSyncUseCase.swift`
5. `ImportOPMLUseCase.swift`
6. `ExportOPMLUseCase.swift`
7. `BootstrapUseCase.swift`

### `AppModel+TranslationStorage.swift` (659)

Status:

1. Keep as one file for now.
2. Revisit only if later changes create multiple parallel modules inside it.

### `ReaderDetailView.swift` (641)

Status:

1. Keep as one file for now.
2. It is still one coherent reader-detail module.

### `AgentExecutionShared.swift` (618)

Status:

1. Keep as one file for now.
2. Re-evaluate only if shared helper groups become independently reusable.

### `TaskQueue.swift` (616)

Status:

1. Keep as one file for now.
2. Queue, policy, and center still form one infrastructure module.

### `AppModel+Agent.swift` (603)

Status:

1. Keep as one file for now.
2. It is configuration-centric and still within one module boundary.

### `DatabaseManager.swift` (551)

Status:

1. Light split is recommended later.
2. The natural boundary is `DatabaseManager` surface vs migrations.

Target split:

1. `DatabaseManager.swift`
2. `DatabaseManager+Migrations.swift`

### `AgentLLMProvider.swift` (517)

Status:

1. Keep as one file for now.
2. It is large but still one provider implementation module.

### `ReaderTheme.swift` (516)

Status:

1. Keep as one file for now.
2. Theme types, rules, presets, and validation still read as one coherent theme module.

---

## Coverage Check Against Current Codebase

This section exists to prevent missing or unnecessary directories. Each target directory below corresponds to current files that already need that ownership boundary.

### `App/Views`

Current files covered:

1. `ContentView.swift`
2. `ContentView+Commands.swift`
3. `ContentView+EntryLoading.swift`
4. `ContentView+FeedActions.swift`
5. `ContentView+Status.swift`
6. `AppSettingsView.swift`
7. `DebugIssuesView.swift`

### `Core/Database`

Current files covered:

1. `DatabaseManager.swift`
2. `Models.swift`
3. `Stores.swift`

### `Core/Tasking`

Current files covered:

1. `TaskQueue.swift`
2. `TaskLifecycleCore.swift`
3. `AppModel+TaskLifecycle.swift`
4. `JobRunner.swift`

### `Core/Shared`

Current files covered:

1. `LanguageManager.swift`
2. `SSBStore.swift`

### `Core/Views`

Current files covered:

1. `SplitDivider.swift`
2. `ToolbarSearchField.swift`
3. `SettingsSliderRow.swift`

### `Feed`

Current files covered:

1. `FeedInputValidator.swift`
2. `FeedTitleResolver.swift`
3. `MarkReadPolicy.swift`
4. `AppModel+Feed.swift`
5. `AppModel+Sync.swift`
6. `AppModel+ImportExport.swift`
7. `SyncService.swift`
8. `OPML.swift`

### `Feed/Views`

Current files covered:

1. `SidebarView.swift`
2. `EntryListView.swift`
3. `FeedEditorSheet.swift`
4. `ImportOPMLSheet.swift`

### `Feed/UseCases`

Current files covered:

1. `UseCases.swift` after splitting into per-use-case files.

### `Feed/Sync`

Current files covered:

1. Feed sync-specific files if split out from `UseCases.swift` and `SyncService.swift`.

Note:

1. If sync remains small after refactoring, it is acceptable to keep those files directly under `Feed/` and remove `Feed/Sync`.

### `Feed/ImportExport`

Current files covered:

1. OPML import/export and bootstrap files after `UseCases.swift` is split.

### `Reader`

Current files covered:

1. `Reader.swift`
2. `ReaderTypes.swift`
3. `Markdown.swift`
4. `AppModel+Reader.swift`

### `Reader/Views`

Current files covered:

1. `ReaderDetailView.swift`
2. `ReaderSummaryView.swift`
3. `ReaderTranslationView.swift`
4. `ReaderSettingsView.swift`
5. `ReaderThemeControls.swift`
6. `ReadingMode.swift`
7. `WebView.swift`

### `Reader/Theme`

Current files covered:

1. `ReaderTheme.swift`

### `Agent/Runtime`

Current files covered:

1. `AgentEntryActivation.swift`
2. `AgentRunCore.swift`
3. `AgentRunStateMachine.swift`
4. `AgentRuntimeEngine.swift`
5. `AgentRuntimeProjection.swift`
6. `AgentRuntimeStore.swift`

### `Agent/Provider`

Current files covered:

1. `AgentLLMProvider.swift`
2. `AgentProviderValidation.swift`
3. `AgentPromptTemplateStore.swift`

### `Agent/Settings`

Current files covered:

1. `AppModel+Agent.swift`
2. `AppModel+AgentAvailability.swift`
3. `AgentSettingsView.swift`
4. `AgentSettingsView+Agent.swift`
5. `AgentSettingsView+Model.swift`
6. `AgentSettingsView+Provider.swift`
7. `AgentSettingsView+Shared.swift`

### `Agent/Summary`

Current files covered:

1. `SummaryContracts.swift`
2. `SummaryPromptCustomization.swift`
3. `SummaryStreamingCachePolicy.swift`
4. `AppModel+SummaryExecution.swift`
5. `AppModel+SummaryStorage.swift`

### `Agent/Translation`

Current files covered:

1. `TranslationBilingualComposer.swift`
2. `TranslationContracts.swift`
3. `TranslationHeaderTextBuilder.swift`
4. `TranslationPromptCustomization.swift`
5. `TranslationSegmentExtractor.swift`
6. `TranslationSegmentTraversal.swift`
7. `AppModel+TranslationExecution.swift`
8. `AppModel+TranslationStorage.swift`

### `Agent/Shared`

Current files covered:

1. `AgentExecutionShared.swift`
2. `AgentFailureClassifier.swift`
3. `AgentFoundation.swift`
4. `AgentLanguageOption.swift`
5. `FailurePolicy.swift`

### `Usage`

Current files covered:

1. `UsageReportContracts.swift`
2. `AppModel+UsageReport.swift`
3. `AppModel+UsageRetention.swift`

### `Usage/Views`

Current files covered:

1. `UsageReportView.swift`
2. `UsageComparisonReportView.swift`
3. `ProviderUsageReportView.swift`
4. `ProviderUsageComparisonReportView.swift`
5. `ModelUsageReportView.swift`
6. `ModelUsageComparisonReportView.swift`
7. `AgentUsageReportView.swift`
8. `AgentUsageComparisonReportView.swift`

Directory sanity result:

1. `Feed/Views` is required.
2. `App/Views` is required.
3. `Core/Views` is justified by shared UI helpers.
4. `Reader/Rendering` was not necessary and has been removed from the target structure.
5. `Usage/Domain` and `Usage/Query` were too fine-grained and have been collapsed into `Usage/`.

---

## Migration Phases

### Phase 1: Directory Re-homing (No behavior changes)

1. Move files to target domain/core directories.
2. Keep file names and APIs unchanged.
3. Keep final paths within the two-level directory limit.
4. Ensure project compiles after each move batch.

Exit criteria:

1. `./scripts/build` passes.
2. No functional behavior changes.

### Phase 2: Low-risk splits

Scope:

1. Split `Feed/UseCases/UseCases.swift` into one use-case type per file.
2. Do not split `ReaderTheme`, `TaskQueue`, `AgentLLMProvider`, or `AppModel+UsageReport` in this phase.
3. Prefer no-op on other `500-900` line files unless a second independent module is discovered.

### Phase 3: Medium-risk splits

Scope:

1. Light split `Core/Database/DatabaseManager.swift` into manager surface and migrations.
2. Re-review `AppModel+Agent`, `AgentExecutionShared`, and `AppModel+TranslationStorage`.
3. Default outcome for those files is to keep them intact unless clear multi-module boundaries emerge.

### Phase 4: High-risk splits

Scope:

1. Split `Agent/Translation/AppModel+TranslationExecution.swift`.
2. Split `Reader/Views/ReaderSummaryView.swift`.
3. Split `Reader/Views/ReaderTranslationView.swift`.
4. Keep `Reader/Views/ReaderDetailView.swift` intact unless Phase 3 review shows a stronger need.

### Phase 5: Cleanup and consistency

1. Remove obsolete wrappers.
2. Normalize naming and `MARK` structure.
3. Align tests and docs to new paths.

---

## Placement Decision Checklist (For New Files)

When adding a new file, apply this order:

1. Is it app entry point / wiring only? Put in `App/`.
2. Is it cross-feature infrastructure? Put in `Core/`.
3. Does it belong to one feature domain? Put in `Reader/`, `Agent/`, `Feed/`, or `Usage/`.
4. Inside a top-level domain, is it `Views`, `Runtime`, `Storage/Query`, or `Contracts`? Place by responsibility, not by type keyword.
5. If responsibility sentence contains two independent verbs, split before adding.

---

## Non-goals

1. No architecture rewrite during structural split.
2. No behavior changes mixed into move/split commits.
3. No broad renaming that obscures git history unless required.
