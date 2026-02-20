# Translate Agent v1 Memo

> Date: 2026-02-19
> Last updated: 2026-02-20
> Status: In Progress (P0-P4 implemented and stabilized for current baseline; further optimization remains)

## Current Snapshot
- Scope decision is fixed for v1:
  - translation is `Reader`-only.
  - no translation support in `Web` mode or `Dual` mode.
  - Reader toolbar adds `Share` actions (`Copy Link`, `Open in Default Browser`) so users can use browser-native translation flows if preferred.
- Core UI/data path is already implemented, and now enters execution optimization/hardening phase.
- P2 hardening progress implemented in current branch:
  - translation run watchdog timeout is added with normalized `timed_out` failure mapping.
  - parser now supports guarded recovery for loose line-based model output after strict JSON parse failure.
  - Reader translation missing-state projection now maps coordinator phases explicitly, including `Persisting...`, and suppresses stale transient statuses without active owner state.
  - render pipeline root-cause fix completed for `run succeeded but body unchanged` issue:
    - translation projection paths are unified for persisted-hit and missing-state rendering.
    - `WKWebView` update path now prefers in-place `article.reader` patch over full reload.
    - patch path preserves scroll position and disables smooth scroll during patch to avoid visible jitter.
    - temporary `Translate Trace` diagnostics were removed after stabilization.

## Current Issue Tracking (2026-02-19)
- P0: execution lifecycle to UI synchronization is not robust
  - Some completed runs remain visually stuck at `Generating` until manual mode toggle.
- P1: parser fault tolerance is weak
  - `Model response cannot be parsed into translation segments.` is recurring for some entries and currently has poor recovery.
- P2: long-article failure handling is incomplete
  - Local model resource exhaustion handling is improved with watchdog timeout and explicit timeout messaging; further tuning remains in P5.
- P3: cross-entry state perception is confusing
  - During one in-flight run, other entries can appear to be generating without a clear waiting/ownership contract.
- P4: queue/clear/progress contracts need stricter formalization
  - waiting semantics, clear scope, and observable progress are not yet as explicit as summary.

## Target Outcomes After P0-P6

### Architecture outcomes
- Translation no longer depends on fragile view-local polling as primary completion sync path.
- Run ownership and terminal states become deterministic and testable (`entryId + slotKey` scoped).
- Translation orchestration aligns with shared-agent contracts, reducing duplication with summary and future agents.
- Waiting/abandon/clear behavior is fully specified and unit-test covered.

### User experience outcomes
- Entry switch always returns to original text; translation starts only on explicit user action.
- Status feedback is unambiguous (`Waiting/Requesting/Generating/Persisting/Failed`), without stale `Generating` dead states.
- Long article and model overload failures surface clearly with recoverable paths instead of indefinite waiting.
- Cross-entry switching no longer creates misleading generation status on unrelated entries.

## 1. Decision
- Drop previous multi-mode translation ideas in v1.
- Keep one clear experience:
  - in Reader view, user can one-click toggle between:
    - original article mode
    - translation mode (inline translated segments)

## 2. v1 Product Contract

## 2.1 Reader-only translation
- Translation UI and execution exist only in Reader mode.
- If current detail mode is `Web` or `Dual`, translation controls are hidden/disabled.
- This is an intentional product boundary for v1, not a temporary bug.

## 2.2 Reader toolbar actions
- Add `Share` button on the right side of the main toolbar.
- Minimum actions:
  - `Copy Link`
  - `Open in Default Browser`

## 2.3 Toggle behavior
- Add one-click toggle in Reader mode:
  - `Translate` (enter translation mode)
  - `Original` (return to original mode)
- Translation has no `auto-translate` mode in v1.
- Every entry switch must reset to `Original` mode by default.
- Entering translation mode is always user-triggered and then:
  - if persisted translation for current slot exists: render persisted translation.
  - if not: enqueue/start translation generation by queue policy.
- If translated result already exists for current slot, render from persisted data directly.

## 2.4 Entry activation state-first invariant (locked)
- On every entry activation/switch, translation pipeline must first resolve persisted state for current slot.
- If persisted translation exists, use it as first rendered state and enable `Clear` immediately.
- Only when no persisted payload is renderable may runtime evaluate start/queue/waiting logic.
- This ordering is a shared high-priority activation path and cannot be replaced by scattered checks in individual start entry points.

## 2.5 Serialized run and waiting contract (locked)
- Translation execution uses serialized scheduling (`max in-flight = 1` for translation kind).
- When a translation run is already active and user clicks `Translate` on another entry:
  - that entry moves to explicit `Waiting for last generation to finish...` state.
- If user leaves a waiting entry before it starts, waiting intent is dropped:
  - no auto-start later for that abandoned entry.
- Only explicit user action can start translation for an entry.

## 2.6 Segment rendering contract
- Translation mode renders article by source segments and inserts translated text below each source segment.
- Segment baseline rules for v1:
  - each HTML `<p>` is one segment.
  - each HTML `<ul>` block is one segment.
  - each HTML `<ol>` block is one segment.
- Non-text or unsupported blocks keep current Reader behavior (no forced translation synthesis).

## 2.7 Settings and prompts
- `Agents > Translation` should provide:
  - `Primary Model`
  - `Fallback Model` (optional)
  - `Target Language` default
  - `custom prompts` action (same external-edit workflow as summary):
    - create sandbox `translation.yaml` from built-in `translation.default.yaml` if missing
    - if file already exists, do not overwrite
    - reveal file in Finder for user-managed editing

## 2.8 Error interaction and empty-state contract (locked)
- Error detail should use a single top banner in Reader detail and appear only when there is an actual failure.
- Inline content areas should stay neutral and stable during failure states:
  - summary empty/failure placeholder text is `No summary`.
  - translation empty/failure placeholder text is `No translation`.
- Avoid question-form retry copy when there is no direct clickable retry action.
- Translation mode must keep translation blocks visible even when translated content is missing; do not remove/hide the block on empty state.
- On new run start, success, or entry switch, stale error banners should be cleared to avoid cross-entry confusion.

## 3. Technical Contracts

## 3.1 Task orchestration
- Follow global async contract:
  - run through `TaskQueue` / `TaskCenter`.
  - no implicit auto-cancel of in-flight runs.
  - explicit abort remains user action.

## 3.2 Persistence model
- Keep shared run base + translation payload strategy:
  - `AITaskRun` for lifecycle/provenance.
  - translation payload tables for segment mapping (`sourceSegmentId/orderIndex/translatedText`).
- Slot key baseline for reuse decision:
  - `entryId + targetLanguage + sourceContentHash + segmenterVersion`.

## 3.3 Prompt template governance
- Translation prompt uses YAML template files with schema validation, same governance model as summary.
- Before `1.0`, keep built-in translation template version policy aligned and stable (`v1`).

## 4. Implementation Plan (Step-based)

### Step 0 — Planning freeze and UX wire contract
#### Scope
- Freeze Reader-only translation scope and segment rules.
- Define toggle state machine and fallback behavior when translation is unavailable.

#### Verification
- Design memo accepted; no conflicting translation path remains in docs.

### Step 1 — Translation settings foundation
#### Scope
- Add `Agents > Translation` settings domain:
  - default target language
  - primary/fallback model mapping
- Add settings storage and migration if needed.

#### Verification
- Settings can persist/load correctly after relaunch.

### Step 2 — Prompt template plumbing
#### Scope
- Add built-in `translation.default.yaml`.
- Add customization helper for sandbox `translation.yaml` copy-if-missing + Finder reveal workflow.
- Add loader validation and runtime resolution path.

#### Verification
- Runtime prefers sandbox template when present.
- Built-in fallback works when sandbox file is absent.

### Step 3 — Reader segment extraction + data model wiring
#### Scope
- Implement deterministic segment extraction from Reader-rendered content (`p`/`ul`/`ol`).
- Generate stable `sourceSegmentId` / `orderIndex` for persistence and render mapping.

#### Verification
- Same entry content yields stable segment ordering across rerenders.

### Step 4 — Translation execution pipeline
#### Scope
- Implement translation run execution with streaming and abort.
- Persist successful translation segments and metadata.
- Ensure slot-based reuse for existing successful translation data.

#### Verification
- Manual translation runs stream and finalize correctly.
- Abort stops run without corrupting persisted success data.

### Step 5 — Reader inline translation UI
#### Scope
- Add `Translate/Original` toggle in Reader mode.
- Render source + translated segment pairs in translation mode.
- Add `Share` button with `Copy Link` and `Open in Default Browser`.

#### Verification
- Toggle is reliable across entry switches and re-open.
- Share actions work from Reader context.

### Step 6 — Policy hardening and tests
#### Scope
- Unit tests for:
  - segment extraction contracts (`p`/`ul`/`ol`)
  - mode toggle state machine
  - slot reuse rules
  - template source selection and copy-if-missing behavior
- Add focused integration tests for Reader translation render composition.

#### Verification
- Targeted test suite passes and covers critical non-visual business rules.

### Step 7 — Acceptance and doc freeze
#### Scope
- Update stage/status docs after implementation.
- Finalize operator-facing and user-facing notes.

#### Verification
- `./build` succeeds.
- Translation acceptance checklist is fully checked.

## 5. Detailed Design — Reader Inline Translation

This section is the implementation-level design for the new translation-specific core feature:
- real-time inline insertion in Reader-rendered HTML
- reliable switching between `Original` and `Bilingual` mode

### 5.1 Architecture summary
- Keep Reader source-of-truth as `Content.markdown` (same baseline as current Reader and summary source fallback path).
- Build translation around deterministic segments extracted from rendered article body.
- Persist translation payload as structured segment rows (not one big text blob).
- Reuse summary-style orchestration patterns:
  - `TaskQueue` / `TaskCenter`
  - no implicit cancellation
  - explicit `Abort` only

### 5.2 Segment extraction contract

#### Input
- Source markdown from `content.markdown` for `entryId`.

#### Extraction rules (v1 locked)
- Segment candidates:
  - each `<p>`
  - each `<ul>` (entire list block as one segment)
  - each `<ol>` (entire list block as one segment)
- Exclusions:
  - `<p>` inside `<ul>/<ol>` should not create extra segments.
  - unsupported blocks keep original-only rendering.

#### Determinism requirements
- Segment order is strict `orderIndex` by DOM traversal order.
- `sourceSegmentId` is deterministic from normalized segment payload:
  - recommended: `seg_<orderIndex>_<hash12>`
- The extractor outputs:
  - `entryId`
  - `sourceContentHash`
  - `segmenterVersion`
  - `[ReaderSourceSegment]` where each item includes:
    - `sourceSegmentId`
    - `orderIndex`
    - `sourceHTML`
    - `sourceText`
    - `segmentType` (`p|ul|ol`)

### 5.3 Translation slot and reuse policy

#### Why summary slot rules are not enough
- Summary payload is a single text block and only depends on run parameters.
- Translation payload must match exact source segment layout. If source changes, old mapping is invalid.

#### Translation slot key (v1)
- `entryId + targetLanguage + sourceContentHash + segmenterVersion`

#### Reuse behavior
- When entering bilingual mode, load persisted translation by current slot key.
- If found: render immediately.
- If missing: show bilingual placeholders and start run (manual trigger in v1 UI path).
- Fetch/read failure is fail-closed:
  - show `Fetch data failed. Retry?`
  - do not auto-start translation task.

### 5.4 Persistence schema (task base + payload)

#### Shared base (already exists)
- `ai_task_run` (`AITaskRun`) remains the lifecycle/provenance base.

#### New payload tables
- `ai_translation_result` (header, success-only durable payload):
  - `taskRunId` (PK/FK to `ai_task_run`)
  - `entryId`
  - `targetLanguage`
  - `sourceContentHash`
  - `segmenterVersion`
  - `outputLanguage`
  - `createdAt`
  - `updatedAt`
- `ai_translation_segment`:
  - `taskRunId` (FK to `ai_translation_result`, cascade delete)
  - `sourceSegmentId`
  - `orderIndex`
  - `sourceTextSnapshot` (optional, debug/provenance)
  - `translatedText`
  - `createdAt`
  - `updatedAt`

#### Index recommendations
- `ai_translation_result`:
  - unique slot index on (`entryId`, `targetLanguage`, `sourceContentHash`, `segmenterVersion`)
  - index on `updatedAt` for cap eviction
- `ai_translation_segment`:
  - index on (`taskRunId`, `orderIndex`)
  - unique on (`taskRunId`, `sourceSegmentId`)

#### Storage lifecycle
- Persist only `succeeded` translation payloads.
- `failed`/`cancelled` runs remain diagnostics-only in `ai_task_run`.
- Apply global cap eviction for translation headers (cascade removes segments).

### 5.5 Reader rendering mode design

#### Mode states
- `original`
- `bilingual`

#### Toggle behavior
- `original -> bilingual`:
  - load translation by slot key
  - if hit: render bilingual immediately
  - if miss: keep bilingual structure + placeholders + run translation
- `bilingual -> original`:
  - show original reader HTML immediately
  - translation run may continue in background (global non-auto-cancel policy)

#### Display model
- Keep source paragraph/list block visible.
- Insert translated block directly below its source segment.
- Per-segment status text while running:
  - `Requesting...`
  - `Generating...`
  - `Waiting for last generation to finish...`

### 5.6 Real-time update strategy (recommended)

To avoid full-page reload flicker and scroll reset, use a patching bridge instead of reloading entire HTML on each token.

#### Implementation status (2026-02-20)
- Current implementation follows this strategy in `WebView` update path:
  - when HTML changes and page is already loaded, patch `article.reader` content in place.
  - preserve `window.scrollX/window.scrollY` before patch and restore after patch.
  - temporarily force `document.documentElement.style.scrollBehavior = 'auto'` during patch, then restore original value.
  - if in-place patch fails, fallback to full `loadHTMLString` refresh.
- This replaced a short-lived forced-rebuild workaround that fixed correctness but introduced visible white flash.

#### Reader HTML compatibility decision (v1)
- v1 implementation baseline is **do not change original Reader rendered HTML structure**.
- Translation behavior should be built as a compatibility layer on top of existing HTML:
  - use `article.reader` as root anchor;
  - find segment candidates with DOM query (`p`, `ul`, `ol`) and filtering rules;
  - inject translation containers/status nodes at runtime via JS bootstrap.
- Rationale:
  - keeps original Reader pipeline and regression surface stable;
  - avoids unnecessary invalidation of existing `content_html_cache`;
  - allows translation feature to iterate independently from Reader base rendering.

#### Future fallback if structural change becomes necessary
- If future work proves original HTML must be changed, apply cache-versioned rollout:
  - add `readerRenderVersion` into Reader cache key composition;
  - force automatic miss-and-rebuild for old cache rows.
- Rule:
  - do not silently reuse old cached HTML after structural contract changes.

#### HTML scaffold
- Bilingual rendering should use runtime-injected anchors/containers without requiring base HTML template changes in v1.
- Runtime scaffold target shape:
  - `<section data-seg-id="...">` (or equivalent marker attached to source block)
  - `<div class="mercury-translation" id="tr-...">...</div>`

#### Runtime bridge
- Extend `WebView` with a lightweight command channel:
  - queue JS patch commands until page load completes
  - apply incremental updates by `sourceSegmentId`
- JS bridge API examples:
  - `window.mercuryTranslation.update(segId, text, isFinal)`
  - `window.mercuryTranslation.setStatus(segId, status)`

#### Fallback rule
- If JS patch fails, fallback to full bilingual HTML refresh at throttled cadence (for example 200-300ms).

### 5.7 Reader cache strategy (vs summary)

#### Shared with summary
- streaming cache should be slot-keyed and bounded by TTL/capacity.
- in-flight entry switch must not leak streaming output across slots.

#### Different from summary
- Summary has only text panel state; no Reader HTML structural composition.
- Translation has two data/cache layers:
  - persisted translation payload (DB, durable)
  - rendered bilingual HTML cache (ephemeral)

#### v1 recommendation
- Do not add a second persistent HTML cache table for bilingual mode in v1.
- Keep bilingual HTML cache in memory only:
  - key: `entryId + themeId + translationSlotKey + translationUpdatedAt`
  - invalidation: theme change, slot change, source hash change, translation update
- Rationale:
  - lower migration complexity
  - avoids stale persisted render cache bugs
  - compose cost is acceptable for v1
- Additional cache contract:
  - original `ContentHTMLCache` read/write behavior remains unchanged in v1 translation implementation.
  - translation-mode runtime DOM bootstrap/patch must not mutate persisted original cache rows.

### 5.8 Orchestration and queue policy
- Use `AppTaskKind.summary` serialized policy pattern as baseline and add `AppTaskKind.translation`.
- Recommended queue limits:
  - global limit can remain higher (for example `5`)
  - translation kind limit `1`
  - summary kind limit `1`
- v1 translation scheduling is manual-only:
  - no entry-switch auto trigger.
  - no hidden background translate intent creation.
- Waiting abandonment rule:
  - if waiting entry is no longer selected before task start, queued waiting intent must be removed.

### 5.9 Error and status policy
- Data fetch/read failure: `Fetch data failed. Retry?` and block start.
- In-flight elsewhere: `Waiting for last generation to finish...`.
- Running current slot with empty text: `Generating...`.
- No payload/no run: `No translation yet.`.

### 5.10 Unit test strategy (high ROI)

Focus tests on non-visual rules that UI regression testing misses:

1. Segment extractor determinism
- same markdown -> same ordered segment IDs.
- list paragraphs do not produce duplicate segments.
- source hash changes when segment-relevant content changes.

2. Slot/reuse/invalidation
- slot hit requires exact match on `entryId + language + sourceHash + segmenterVersion`.
- source hash mismatch must be treated as miss.

3. Mode state machine
- toggle behavior for:
  - hit/miss
  - in-flight run
  - entry switch + switch back
- ensure no streaming text leakage across entry/slot.

4. Streaming patch state
- per-segment token aggregation correctness.
- TTL/cap eviction keeps pinned (running/current-display) slot states.

5. Failure gate policy
- fetch failure returns `showFetchFailedRetry` decision and blocks auto-start.

## 6. Summary vs Translation — storage/cache comparison

### Similarities
- shared `ai_task_run` lifecycle/provenance model.
- success-only durable payload persistence.
- slot-based selection and streaming cache isolation.
- fail-closed pre-start fetch policy with explicit retry affordance.

### Differences
- Summary:
  - slot key: `entryId + targetLanguage + detailLevel`
  - payload: one text block
  - render target: Summary Panel text
- Translation:
  - slot key: `entryId + targetLanguage + sourceContentHash + segmenterVersion`
  - payload: segment-mapped rows
  - render target: Reader HTML inline bilingual composition
  - requires DOM patch path for smooth streaming UX

## 7. Reusable Mechanism Matrix (Summary -> Translation)

This section defines what should be reused directly, what should be adapted, and what is translation-specific.

### 7.1 Direct reuse (same contract)
- Task scheduling foundation:
  - `TaskQueue` / `TaskCenter` enqueue/cancel/state updates/debug issue integration.
- Shared run lifecycle:
  - `AITaskRun` fields and status transitions (`queued/running/succeeded/failed/cancelled`).
- Provider/model routing:
  - primary/fallback route resolution and capability filtering.
- Prompt template governance:
  - built-in YAML + sandbox override + runtime validation + template provenance.
- Failure surface baseline:
  - fail-closed pre-start check and explicit retry affordance.
- Streaming state hygiene:
  - slot-keyed state cache + TTL/capacity eviction + pinned-key protection.

### 7.2 Existing implementation assets from summary track (already in codebase)
- Queue and lifecycle foundation:
  - `TaskQueue` + `TaskCenter` event/state flow and per-kind concurrency limit.
- Summary execution and storage contracts:
  - `AppModel+AISummaryExecution.swift`
  - `AppModel+AISummaryStorage.swift`
- Proven stable policy modules:
  - `SummaryAutoStartPolicy`
  - `SummaryAutoPolicy`
  - `SummaryStreamingCachePolicy`
- Proven UI contracts in `ReaderDetailView`:
  - running slot ownership
  - waiting placeholder semantics
  - fail-closed fetch retry gate (`Fetch data failed. Retry?`)

### 7.3 Reuse with adaptation
- Slot key policy:
  - summary slot includes `detailLevel`;
  - translation slot must include `sourceContentHash + segmenterVersion`.
- Result storage policy:
  - both are success-only durable payloads;
  - translation payload shape is multi-row segment mapping.
- UI status semantics:
  - summary is panel-based;
  - translation is in-article segment-based and needs per-segment status text.

### 7.4 Translation-specific additions
- Deterministic segment extractor and stable `sourceSegmentId`.
- Inline bilingual HTML composer.
- `WKWebView` incremental patch bridge for real-time segment updates.
- Translation payload tables and segment-level merge/query path.

### 7.5 Required extraction to true shared modules
- Move agent-generic orchestration out of summary-specific naming:
  - queue binding, run state projection, waiting abandonment, timeout/watchdog hooks.
- Introduce shared `AgentRunCoordinator` contract:
  - state machine, entry/slot ownership, serialized waiting queue behavior.
- Keep task-specific logic pluggable:
  - request builder, parser, payload persistence, slot-key composition.

## 8. LLM Request Construction Strategies

All three strategies remain valid; v1 should pick a primary path and keep the others as explicit future options.

### 8.1 Strategy A — single request for whole article

#### Shape
- Build one request using all extracted segments.
- Ask model to return structured output keyed by `sourceSegmentId`.

#### Pros
- Best global context and terminology consistency.
- Simplest run lifecycle (`1 task = 1 request`).
- Easiest to align with current summary orchestration path.

#### Cons
- Long articles can approach context/token limits.
- One failure can require rerunning whole article.
- Strong output-format guardrails are required.

#### Good fit
- v1 default path.

### 8.2 Strategy B — per-segment requests (possibly parallel)

#### Shape
- Send one request per segment, optionally with bounded concurrency.

#### Pros
- Failure isolation is strong; easy per-segment retry.
- Fast first-visible output for early segments.

#### Cons
- Cost and request overhead are highest.
- Terminology/style drift risk across segments.
- Complex orchestration and queue pressure management.

#### Good fit
- future optimization mode for ultra-long articles or partial retry tooling.

### 8.3 Strategy C — chunked multi-segment requests

#### Shape
- Group segments into chunks, each chunk one request.
- Model returns structured segment mapping per chunk.

#### Pros
- Better scale behavior than full-single-request.
- Better consistency/cost profile than per-segment requests.
- Failure scope smaller than strategy A.

#### Cons
- Requires chunking/merge logic and chunk-level recovery.
- Cross-chunk consistency still weaker than full context.

#### Good fit
- fallback path when article size exceeds v1 strategy A budget.

### 8.4 Comparative summary
- Quality consistency:
  - best: `A`, then `C`, then `B`.
- Operational simplicity:
  - best: `A`, then `C`, then `B`.
- Failure isolation:
  - best: `B`, then `C`, then `A`.
- Cost control:
  - usually best: `A` or `C` (depends on chunking), worst: `B`.

### 8.5 Recommended policy for v1
- Primary: strategy `A` (single request, structured mapped output).
- Fallback: strategy `C` only when size thresholds are exceeded.
- Deferred: strategy `B` (not in v1 default scope).

## 9. Step-by-step Implementation Plan (based on above decisions)

This plan refines Step 0-7 into execution phases with explicit gates.

### Phase P0 — Product contract hard-freeze (manual-only mode)
0. Lock entry activation state-first ordering:
   - resolve/render persisted slot state first.
   - only then evaluate run start/queue rules.
1. Lock no-auto-translate behavior:
   - entry switch always resets to `Original`.
   - translation starts only by explicit user click.
2. Lock serialized waiting policy:
   - translation in-flight limit `1`.
   - waiting entry abandoned on leave.
3. Freeze status vocabulary:
   - `No translation yet.`
   - `Waiting for last generation to finish...`
   - `Requesting...`
   - `Generating...`
   - `Persisting...`
   - `Fetch data failed. Retry?`

Gate:
- Product/engineering review confirms no ambiguous auto-trigger path remains.

### Phase P1 — Shared mechanism extraction from summary path
1. Inventory and mark already-usable summary mechanisms:
   - queue/event plumbing
   - run lifecycle projection
   - waiting/fail-closed status mapping.
2. Extract shared coordinator interfaces (agent-agnostic):
   - run state machine
   - waiting queue semantics
   - active slot ownership and abandonment rules.
3. Keep translation-specific adapters behind protocol boundaries.

Gate:
- Shared contracts documented in `docs/agent-share.md` and first adapter compile path is green.

### Phase P2 — Translate execution hardening on shared coordinator
1. Bind translation UI to coordinator state (remove fragile ad-hoc completion polling dependencies).
2. Add run-level timeout/watchdog and explicit terminal error mapping.
3. Improve parser tolerance/recovery:
   - strict parse + guarded recovery path for model formatting drift.
4. Keep strategy `A` primary and `C` fallback; do not enable `B`.

Gate:
- `Generating` stale-state bug is closed in deterministic tests.
- parser failure path emits actionable failure states and no dead loop.

### Phase P3 — Progress model and UI projection
1. Replace opaque status with phase + chunk progress projection:
   - phase: requesting/generating/persisting
   - progress: chunk `i/n` where applicable.
2. Ensure cross-entry isolation:
   - only selected entry/slot state is rendered.
   - other in-flight entries do not appear as local generating unless explicitly waiting.
3. Maintain manual toggle semantics with immediate `Original` fallback.

Gate:
- entry-switch behavior is stable and user-perceived status is unambiguous.

### Phase P4 — Clear policy formalization
1. Define and implement two clear scopes:
   - clear current slot (`entry + language + sourceHash + segmenterVersion`)
   - clear all translations for current entry (all languages/versions).
2. Make clear actions explicit in UI with clear label/intent.
3. Add integrity tests for cross-language/version deletion behavior.

Gate:
- clear behavior matches specification and leaves no ambiguous stale payload path.

### Phase P5 — Efficiency tuning under safety constraints
1. Introduce adaptive chunk sizing using model-context budget.
2. Add bounded chunk-level retry with failure classification.
3. Keep translation kind serialized by default; evaluate bounded intra-run parallelism only behind explicit threshold + guard.

Gate:
- long-article runs show improved success/latency without stability regression.

### Phase P6 — Acceptance and documentation close
1. Run `./build`.
2. Run translation-focused test suite and required coordinator shared tests.
3. Update `docs/stage-3.md` status and acceptance checklist.

Gate:
- build/test gates pass and docs reflect final runtime contract.

## 10. Open Questions (resolved for v1 baseline)
- `<blockquote>`:
  - v1 keeps it original-only (not a segment type).
- auto-translate:
  - v1 is manual trigger only.
  - auto-trigger is explicitly out of scope and should not be added as hidden behavior.
- template version in slot:
  - not part of slot key in v1.
  - keep as run provenance metadata in `ai_task_run`.

## 11. Pre-close Focus — Core Translation Completion Tasks

This section records the prioritized completion scope before closing `Translate Agent`.
P0 closure tasks and broad documentation sync remain required, but should be executed after the core runtime and UX robustness tasks in this section are finalized.

### 11.1 Entry-switch policy alignment with summary (robustness first)

Goal:
- Align translation behavior with summary for cross-entry switching while preserving translation-specific manual-start rules.

Required outcomes:
- If a translation run is in-flight for entry A and the user switches to entry B:
  - entry B must not show false `Generating` state unless B is explicitly queued as waiting.
  - entry A run continues unless user explicitly aborts (global non-auto-cancel policy).
  - waiting ownership and abandonment-on-leave behavior must be deterministic and test-covered.
- State projection must stay entry/slot isolated:
  - selected entry renders only its own projected state.
  - no cross-entry transient status leakage.

Implementation direction:
- Reuse `AgentRunCoordinator` state and promotion flow as the authoritative source for waiting/running ownership.
- Keep translation manual trigger semantics, but align lifecycle transitions and waiting replacement rules with summary contracts.

Acceptance checks:
- Rapid entry switching does not produce stale or duplicated `Generating` status.
- Waiting entry is dropped when user leaves before start.
- In-flight run completion for non-selected entry does not incorrectly mutate current entry UI state.

### 11.2 Request construction optimization (A/C strategy evolution)

Goal:
- Improve reliability and cost/performance balance for long articles while keeping strategy A as the default path.

Required outcomes:
- Keep primary path: strategy A (single request for whole article) when within budget.
- Use strategy C (chunked requests) by deterministic thresholding for large payloads.
- Improve chunk policy to reduce avoidable parser failures and oversize requests.

Optimization tasks:
- Revisit token estimation and chunk sizing heuristics with runtime telemetry.
- Add bounded chunk-level retry policy with explicit failure classification.
- Keep strategy B deferred by default (do not enable per-segment fan-out in baseline path).

Acceptance checks:
- Long-article success rate improves without regressions in normal-size articles.
- Request count and error profile are observable from runtime snapshot fields.

### 11.3 Segment-aware streaming projection from LLM output

Goal:
- Evaluate and implement robust segment-targeted streaming so translated segments can update progressively in UI.

Target capability:
- Consume streaming tokens and project updates to specific `sourceSegmentId` blocks in Reader translation mode.
- Preserve deterministic final merge and validation with fail-closed behavior.

Minimum robustness requirements:
- Streaming parser must tolerate partial JSON and incomplete segment blocks.
- UI update path must be idempotent and segment-scoped.
- Terminal reconciliation must validate full coverage before success persistence.
- On malformed streaming output, fallback to repair/completion flow without dead state.

Implementation direction:
- Introduce a segment-stream accumulator that tracks per-segment partial payloads.
- Emit projection events per segment update, then finalize through the existing persistence validator.
- Keep full-response parsing path as a safety fallback.

Acceptance checks:
- Visible progressive segment updates for streaming-enabled models.
- No cross-segment corruption during partial token bursts.
- Final persisted output remains schema-valid and complete.

### 11.4 Swift 6 warning reduction for generated test macro code

Observed issue class:
- Swift Testing macro expansion can generate warnings like:
  - `Main actor-isolated conformance ... cannot be used in nonisolated context; this is an error in the Swift 6 language mode`.

Goal:
- Reduce or eliminate actor-isolation warnings in test target generated sources.

Mitigation direction:
- Avoid relying on `Equatable` assertions for main-actor-isolated types in nonisolated test contexts.
- Prefer field-level assertions or nonisolated projection snapshots for equality checks.
- Where appropriate, move comparison targets to value snapshots that are explicitly `Sendable` and nonisolated.

Acceptance checks:
- Warning count from generated test macro sources is significantly reduced.
- No loss of critical assertion coverage for coordinator/pipeline logic.

### 11.5 Execution order before final close

1. Complete 11.1 / 11.2 / 11.3 / 11.4 and pass build + targeted tests.
2. Execute P0 closure tasks (diagnostic report export path and single-surface error consistency finalization).
3. Run full documentation sync (`translate`, `stage-3`, shared contracts, user-facing docs) and freeze acceptance checklist.
