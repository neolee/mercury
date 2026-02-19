# Summary Agent v1 Memo

> Date: 2026-02-17
> Last updated: 2026-02-19
> Status: Closed (Step 1-7 completed)

## Current Snapshot
- Implemented:
  - Step 1: summary storage schema + slot replacement + cap enforcement.
  - Step 2: YAML template loading/validation/rendering + unit tests.
  - Step 3: Reader Summary Panel UI (collapse/expand, resize, toolbar, metadata, copy/clear).
  - Step 4: summary execution backend (streaming, abort, persistence, diagnostics policy).
  - Step 5: summary agent defaults in settings and panel synchronization.
  - Step 6: `Auto-summary` behavior and session override policy wiring.
  - Step 7: end-to-end acceptance checklist freeze and final doc polish.

## 1. Decision
- First AI assistant feature remains `summary` (not `translation`).
- `summary` must support **target language** in v1.
- Rationale:
  - High utility with lower UI complexity than bilingual translation rendering.
  - Output can be shown as an independent result block/panel.

## 2. Agent Contract Adjustment

## 2.1 Required/optional runtime parameters
- `entryId: Int64`
- `sourceText: String`
- `targetLanguage: String` (required, BCP-47 code, from agent default or panel selection)
- `detailLevel: short | medium | detailed`
- `systemPromptOverride: String?` (reserved; not wired in current execution path)

## 2.2 Configuration vs panel runtime state
- Agent configuration keeps a persistent default:
  - `defaultTargetLanguage` (required)
  - `defaultDetailLevel`
  - `primaryModelProfileId`
  - `fallbackModelProfileId?`
- Panel runtime state can temporarily choose:
  - `targetLanguage`
  - `detailLevel`
- Runtime choice applies to the run execution request and does not mutate saved defaults.
- Selection policy for entries without persisted summary:
  - if the selected entry has an in-flight summary run, panel controls should follow that run's slot parameters (`entryId + targetLanguage + detailLevel`)
  - otherwise panel controls should reset to `Agents` settings defaults for summary

## 3. Prompt/System Design
- Use English templates for maintainability and model consistency.
- Keep target language as a template variable (not hardcoded prompt variants).
- Keep output plain text in v1 (stream-friendly, no strict JSON dependency).
- Require “no hallucinated facts” and “state uncertainty explicitly if needed”.

## 4. UI Direction (Reader Workflow)

## 4.1 Entry point and layout
- Do not add a unified top-level `AI Assistant` toolbar button in v1.
- Add a dedicated `Summary Panel` below reader content in the detail area.
- Panel is collapsible and can stay open as a persistent reading companion.

## 4.2 Summary panel structure (minimal v1)
- Toolbar controls:
  - `Target Language` (compact picker)
  - `Detail Level` (compact segmented control)
  - `Summary`
  - `Abort`
  - `Copy`
  - `Clear`
  - `Auto-summary` (checkbox)
- Metadata row (single line under toolbar):
  - target language
  - detail level
  - timestamp
  - duration
- Content area:
  - streaming summary text
  - final stable text after completion

### Toolbar compactness guideline
- Keep controls in one row where possible.
- Prefer compact control styles and abbreviated labels to reduce visual weight.
- Prioritize command buttons and status readability over large form controls.

## 4.3 Result presentation
- Summary output is shown only in this panel (not inline mixed with article body).
- Panel supports manual rerun (`Summary`) and cancellation (`Abort`) during streaming.
- `Copy` copies current output text.
- `Clear` is destructive and clears both:
  - current panel display output
  - persisted summary result data for the current selected entry

## 4.4 Auto-summary safety rules (agreed)
- Inherits the global async orchestration policy: no implicit cancellation of in-flight tasks without explicit user intent.
- Trigger only when selected entry has no existing summary result (any parameter combination).
- Debounce entry switching before run (`1s`) to avoid churn on rapid navigation.
- Auto scheduling uses serialized strategy by default (no parallel auto-summary runs).
- Do not auto-cancel in-flight background summary runs unless user explicitly triggers `Abort`.
- If selected entry already has one or more summary results, show existing result directly and auto-select the parameter combination associated with that shown result.
- Auto-summary failures are surfaced to users directly and do not auto-retry.

## 5. Technical Scope Update
- Implement `summary` pipeline first with:
  - routing (`taskType=summary` -> primary/fallback model)
  - streaming output
  - cancellation
  - result persistence (shared run/result base + summary payload)
- `translation` remains next feature and will later require paragraph-aligned bilingual reader UI.

## 5.1 Unified AI result storage strategy (cross-agent)
- Use one shared base run/result structure for all agents, plus task-specific payload tables.
- Do not force all outputs into one oversized table.

### Shared base layer
- Suggested shared entity: `AITaskRun` (or `AIResultBase`)
- Common fields:
  - `id`
  - `entryId`
  - `taskType` (`summary` / `translation` / `tagging`)
  - `status` (`queued/running/succeeded/failed/cancelled`)
  - `assistantProfileId`
  - `providerProfileId`
  - `modelProfileId`
  - `promptVersion`
  - `targetLanguage` (nullable, task-dependent)
  - `durationMs`
  - `createdAt`
  - `updatedAt`
- Purpose:
  - unified task history and diagnostics context
  - rerun/retry/cancel entry point
  - shared metadata rendering in UI

### Task-specific payload layer
- `AISummaryResult`:
  - `taskRunId`
  - `text`
  - `detailLevel`
  - `outputLanguage`
- `AITranslationResult` + `AITranslationSegment`:
  - translation header references `taskRunId`
  - segment rows store paragraph mapping:
    - `sourceParagraphId`
    - `translatedText`
    - `orderIndex`
- `AITaggingResult` + `AITaggingItem`:
  - tagging header references `taskRunId`
  - item rows store:
    - `tag`
    - `confidence` (optional)

### Why this structure
- Keeps orchestration and lifecycle management unified.
- Preserves strong schema semantics for each task type.
- Avoids fragile all-in-one JSON payload design.

## 5.2 Summary persistence policy (confirmed)
- Persist only successful summary outputs.
- Do not persist `failed` or `cancelled` summary payloads.
- Keep one effective record per parameter slot.

### Parameter slot key
- `taskType + entryId + targetLanguage + detailLevel`

### Write behavior
- If a new successful run lands on the same slot key, replace the previous stored success for that slot.
- This means each slot keeps only the latest successful summary.

### Global storage cap
- Apply a global rolling cap on stored successful summary records (`default = 2000`).
- When cap is exceeded, delete oldest records first by recency field (`updatedAt`/`createdAt`).
- Future extension: expose this cap in `AI Settings` under a dedicated storage-oriented section/tab.

### Failure visibility
- `failed` / `cancelled` runs should still be surfaced through diagnostics (`Debug Issues`) for troubleshooting.
- They should not consume durable summary result storage.

## 5.3 Panel selection policy (confirmed)
- Persistent defaults are managed in `Agents` settings (`defaultTargetLanguage`, `defaultDetailLevel`).
- When selected entry has no persisted summary and no in-flight run for that entry, panel controls reset to agent defaults.
- If selected entry has an in-flight summary run, panel controls follow that run's slot parameters until terminal state.
- If selected entry has persisted summary records, panel shows latest persisted slot and aligns controls to that persisted slot.

## 5.4 Prompt template source-of-truth policy (confirmed)
- System prompts and prompt templates should be file-based, not hardcoded in source and not stored as large text blobs in normal configuration tables.
- Use a human-friendly editable format:
  - `YAML` files for template definitions
  - schema validation for template structure and required placeholders
- Database stores template references and runtime metadata (not the full long template body for normal operations).

### Suggested storage model
- Built-in templates:
  - shipped with app bundle (read-only baseline)
- User/contributor overrides:
  - stored in app support folder (editable/importable)
- Runtime:
  - load, validate, and cache templates in memory on app start or on-demand

### Metadata and traceability
- Each run records:
  - `templateId`
  - `templateVersion`
  - parameter snapshot used for rendering
- This ensures output provenance and reproducibility without forcing full prompt text persistence in primary config tables.

### Current template schema and resolution rules (implemented)
- Template file location (built-in): `Mercury/Resources/AI/Templates/summary.default.yaml`
- Core fields:
  - `id`
  - `version`
  - `taskType`
  - `systemTemplate`
  - `template`
  - `defaultParameters` (`key=value` list, optional but recommended)
  - `optionalPlaceholders` (rare exceptions only)
- Placeholder resolution order:
  - `resolvedParameters = defaultParameters + runtimeOverrides`
  - Runtime values override template defaults when keys collide.
- Required parameter policy:
  - If `requiredPlaceholders` is explicitly provided, it is enforced as the source of truth (legacy-compatible mode).
  - Otherwise required placeholders are auto-derived from placeholders found in `systemTemplate` + `template`, minus `optionalPlaceholders`.
- Validation guarantees:
  - All required placeholders must resolve to non-empty values before render.
  - `optionalPlaceholders` must exist in template bodies (no dead declarations).
  - If both `requiredPlaceholders` and `optionalPlaceholders` exist, overlap is rejected.
- Runtime-side responsibility:
  - Pass only dynamic context (for example `targetLanguage`, `targetLanguageDisplayName`, `detailLevel`, `sourceText`).
  - Keep strategy constants (length ranges, bullet count, etc.) in template `defaultParameters`.

### Language parameter guideline (implemented)
- Prompt-facing language should use a human-readable English display string:
  - `targetLanguageDisplayName` (for example `Chinese (Simplified, zh-Hans)`)
- BCP-47 code remains part of runtime metadata/storage and can be included as parenthetical context in display string.
- Avoid using bare language codes as the only language signal in prompt text.

## 5.5 Standardization strategy (POML-aware, staged adoption)
- Near term:
  - use project-native `YAML + template renderer + schema validation` as the stable implementation path
- Mid term:
  - keep template schema fields compatible with future richer prompt standards (for example explicit `id/version/input/output` metadata)
- POML stance:
  - POML is a useful reference and inspiration for structured prompt design
  - do not fully depend on POML runtime/tooling in current stage
  - keep migration path open if ecosystem maturity and Swift-side integration cost become favorable later

## 6. Implementation Plan (Milestone-based, verifiable)

### Step 1 — Data schema and storage contracts
#### Implementation scope
- Add shared run base table (`AITaskRun` or equivalent).
- Add summary payload table (`AISummaryResult`).
- Enforce persistence rules:
  - success-only durable records
  - latest-success-only per slot key (`taskType + entryId + targetLanguage + detailLevel`)
  - global cap eviction (`default = 2000`)
- Add trace fields: `templateId`, `templateVersion`, runtime parameter snapshot.

#### User-verifiable output
- DB migrations are applied successfully on app startup.
- New schema can store and query one successful summary record end-to-end.

#### Verification criteria
- Run `./build` with no warnings/errors.
- Manual DB check confirms:
  - one row in run base + one row in summary payload after a mocked insert path
  - re-insert with same slot replaces prior success
  - cap cleanup policy hook exists and is callable

### Step 2 — Prompt template file system and validation
#### Implementation scope
- Add file-based template loader for built-in YAML templates.
- Add schema validation for template structure/placeholders.
- Add in-memory template cache and lookup by `templateId`.

#### User-verifiable output
- App can load default summary template from file and reject malformed template files.
- Template defaults and runtime overrides can be merged deterministically (`defaults + overrides`).
- Optional placeholders are explicitly controlled by `optionalPlaceholders`; all other used placeholders are treated as required by default.

#### Verification criteria
- Run `./build` with no warnings/errors.
- Positive test: valid template loads and can render with sample parameters.
- Negative test: invalid template triggers validation failure with actionable error message.

### Step 3 — Reader Summary Panel UI (forward for early visible validation)
#### Implementation scope
- Add collapsible summary panel below reader content.
- Toolbar controls:
  - target language input
  - detail control
  - `Summary / Abort / Copy / Clear`
  - `Auto-summary` checkbox (behavior wiring in later step)
- Add metadata row and streaming text area.
- Keep this step focused on visible workflow entry and UI command contract.

#### User-verifiable output
- Reader shows working panel with full command set and metadata.

#### Verification criteria
- Run `./build` with no warnings/errors.
- Manual checks:
  - panel collapse/expand works
  - `Copy` copies current text
  - `Clear` clears displayed text and current slot persisted summary data
  - `Summary`/`Abort` command states are visible and controllable
  - switching `Reader / Web / Dual` mode does not change summary panel height unexpectedly
  - switching entry does not rebuild the full right pane and does not cause theme flash artifacts

#### Implementation note (layout stability)
- Keep the reader upper pane host tree stable under `VSplitView`.
- Do not `switch`-replace upper pane root content by mode.
- Keep fixed slots for reader/web and switch mode via slot visibility/size.
- Inactive slots should use lightweight placeholders instead of keeping live `WKWebView` instances.
- Use loading overlay transitions for reader content refresh; avoid resetting `readerHTML` to `nil` before new HTML is ready.

### Step 4 — Summary execution backend (orchestration + provider call)
#### Implementation scope
- Implement summary run path through `TaskQueue` / `TaskCenter`.
- Resolve model routing (primary + fallback).
- Support streaming, abort, and finalization into persistent storage.
- Send `failed/cancelled` to diagnostics without durable payload save.

#### User-verifiable output
- One summary run can be started, streamed, aborted, retried, and completed.

#### Verification criteria
- Run `./build` with no warnings/errors.
- Manual run checks:
  - `Summary` starts task and streams text
  - `Abort` cancels active task
  - successful run persists result
  - failed/cancelled run does not create durable summary payload

### Step 5 — Agent defaults in settings (already implemented in current branch baseline)
#### Implementation scope
- Enable summary agent defaults in `Agents` settings:
  - `defaultTargetLanguage` (BCP-47)
  - `defaultDetailLevel`
  - model bindings
- Replace in-panel prompt text editing with `custom prompts` action:
  - click `custom prompts` to create sandbox file `summary.yaml` (copy from `summary.default.yaml` on first use)
  - if `summary.yaml` already exists, do not overwrite
  - reveal `summary.yaml` in Finder and let user edit with any external editor
  - runtime prompt resolution should prefer sandbox `summary.yaml`, fallback to built-in template when missing

#### User-verifiable output
- Settings changes are saved and used as next-run defaults.

#### Verification criteria
- Run `./build` with no warnings/errors.
- Manual checks:
  - saved defaults persist across app relaunch
  - runtime panel initial values on fresh launch reflect saved agent defaults

### Step 6 — Auto-summary behavior and session override rules
#### Implementation scope
- Follow global task orchestration policy:
  - no implicit cancellation of in-flight tasks unless explicit user action (`Abort`) or clearly documented safety rule
- Apply agreed safety rules:
  - trigger only when selected entry has no existing summary (any parameter combination)
  - debounce selection change (`1s`)
  - serialized auto scheduling (no parallel auto runs)
  - do not auto-cancel in-flight run unless user explicitly aborts
  - no automatic retry on failures
  - pre-start persisted-summary check is fail-closed:
    - if persisted-summary fetch fails, do not auto-start
    - show `Fetch data failed. Retry?` in panel
    - `Retry` retries only the fetch/check step, then re-evaluates start decision
  - auto-start decision path must be centralized in one policy entry point (avoid scattered guards)
  - queued auto run keeps latest selection only (strategy A):
    - if user leaves a waiting entry before it starts, that queued entry is dropped
    - latest selected eligible entry replaces previous queued auto candidate
- Add auto-summary enable risk confirmation policy:
  - by default, show warning every time user enables `Auto-summary`
  - allow user to disable repeated warning via `Don't ask again`
  - provide a settings toggle to restore/disable warning behavior later
- Implement panel selection policy wiring for defaults and in-flight slot consistency.

#### User-verifiable output
- Auto-summary behaves predictably during rapid entry switching and respects session memory rules.

#### Verification criteria
- Run `./build` with no warnings/errors.
- Manual checks:
  - rapid entry switching does not create task storms
  - only one auto-summary run is active at a time
  - enabling `Auto-summary` shows warning by default, and respects warning preference
  - existing summary entries do not auto-regenerate unnecessarily
  - in-flight run is not auto-killed by mode/entry changes unless user chooses `Abort`
  - failures are surfaced to user and are not retried automatically
  - no-summary entries reset to settings defaults unless an in-flight run for that entry exists

### Step 7 — End-to-end acceptance and documentation freeze
#### Implementation scope
- Run full summary workflow validation.
- Finalize docs and known limitations for v1.

#### User-verifiable output
- A complete demo path from settings to reader usage is stable and repeatable.

#### Verification criteria
- Run `./build` with no warnings/errors.
- End-to-end checklist passes:
  - summary generation in configured target language
  - streaming + abort + retry
  - persistence and replacement behavior per slot
  - global cap policy behavior
  - diagnostics behavior for non-success runs

## 7. Confirmed Product Decisions
- `Target Language` is picker-based with a curated language list in v1.
- The curated list must include at least: Chinese, English, Japanese.
- Language values are stored and processed using BCP-47 codes (for example `zh`, `en`, `ja`).
- `Target Language` and `Detail Level` controls live directly on the `Summary Panel` toolbar.
- Panel selection policy:
  - no-summary entries use `Agents` settings defaults
  - active in-flight run keeps its slot parameters while running
  - persisted summaries realign controls to persisted slot parameters
- Summary storage global rolling cap default is `2000`, with planned future configurability in AI storage settings.
- Auto-summary enable warning policy:
  - default behavior is warning on every enable action
  - user can opt out with `Don't ask again`
  - warning behavior can be toggled again from settings
- Auto-summary orchestration policy:
  - debounce is fixed at `1s`
  - serialized strategy (`2`) is the default for v1
  - no implicit auto-cancel of in-flight runs; only explicit `Abort` cancels
  - no automatic retry on failures
  - persisted-summary pre-start check is mandatory and fail-closed on fetch errors
  - fetch failure surfaces inline retry action (`Fetch data failed. Retry?`)
  - queued auto behavior uses strategy A (latest-only replacement while waiting)
  - future batch needs are covered by a separate feature track (for example unread digest / bulk summary), not by changing single-entry auto queue semantics
- Template version policy before `1.0`:
  - keep `summary.default.yaml` `version` at `v1`
  - runtime trace `templateVersion` should remain aligned with template file version
