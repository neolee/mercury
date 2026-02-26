# Translation Agent Redesign

Date: 2026-02-26
Status: Design approved — replaces all prior improvement drafts and A/B/C strategy framing

---

## 1. Goal

Redesign the translation execution model to eliminate the structural causes of high failure rates
and long periods of user-visible inactivity. This is a ground-up redesign of the execution layer;
the persistence schema and UI contract are preserved with a targeted migration.

---

## 2. Current State and Problem Diagnosis

### 2.1 Execution model overview

The current implementation has three named execution strategies (A, B, C):

- **Strategy A** (whole-article single request): pack all segments with their IDs into a JSON
  payload, ask the model to return a `{sourceSegmentId: translatedText}` map. Used for most
  articles by default.
- **Strategy C** (chunked requests): split segments into token-budget chunks; send each chunk with
  the same JSON-in / JSON-out contract, serially. Used for large articles.
- **Strategy B** (per-segment): one request per segment. Defined in contracts but explicitly
  deferred; never implemented.

The execution is wrapped in a multi-layer failure recovery pipeline:
1. Primary JSON parse attempt with several extraction heuristics.
2. Loose-line recovery heuristic for partially malformed output.
3. Output repair request — a second LLM call asking the model to fix its own malformed response.
4. Missing-segment completion request — a third LLM call for any segment IDs still absent after
   the above steps.

### 2.2 Root cause: imposing a structured-output contract on a plain-text task

Translation is a plain-text task: given a passage in language X, produce its equivalent in
language Y. The current implementation wraps this in a structured-output contract (JSON segment
map) as the only mechanism for associating source segments with their translations.

This contract fails predictably in three independent ways:

**a. Model capability gap.**
MT-specialized models (e.g., Hunyuan MT 1.5) achieve near-SOTA translation quality at very low
latency and cost, but have minimal instruction-following capacity and do not support structured
output at all. They are entirely incompatible with the current pipeline. General-purpose models
(e.g., DeepSeek, GPT-series) handle JSON output but still fail the contract non-trivially as
article length grows — every such failure triggers the expensive multi-stage repair pipeline.

**b. Failure probability scales with article length.**
A single malformed or omitted key in a large JSON payload fails the entire batch. The probability
of at least one such failure grows with the number of segments. The repair pipeline mitigates
some cases but adds latency and API cost on every failure, and cannot compensate when the model
response is severely malformed.

**c. Serial execution blocks all user feedback.**
Both Strategy A and Strategy C produce no user-visible output until the entire run succeeds.
Strategy C is serial: each chunk must complete before the next begins. A 60-segment article with
`chunkSizeForStrategyC = 24` produces three serial requests; if the first two succeed but the
third times out after 300 s, the user has waited five minutes and sees nothing.

### 2.3 The repair pipeline is a symptom, not a safety net

The three-stage repair pipeline exists because the structured-output contract cannot be fulfilled
reliably. It adds API calls on every failure, creates additional prompt-injection surface, adds
observable latency, and makes the execution trace difficult to follow. In the per-segment design
described below, the parse/repair pipeline has no reason to exist and is removed in its entirety.

### 2.4 User experience profile today

- Time to first visible translation: full article duration (no partial delivery).
- Failure granularity: any segment ID mismatch, JSON parse error, or coverage gap fails the
  entire run.
- Long-article failure mode: execution timeout after 300 s with no partial result preserved.
- MT-specialized models: completely unusable.

---

## 3. Future Vision

### 3.1 Per-segment approach as the single execution mode

Each segment is sent as an independent translation request. The prompt is minimal:

```
System: You are a professional translator.
User:   Translate the following text to {targetLanguage}. Output the translation only.

        {sourceText}
```

No JSON. No segment IDs in the prompt or response. No structured-output contract of any kind.
The source-segment-to-translation association is established by the fact that each request carries
exactly one segment and returns exactly one plain-text translation.

This is the only execution mode going forward. The batch approaches (whole-article and chunked)
are removed from the execution path entirely.

Requests for all segments in an article run with bounded concurrency (default: 3, user-adjustable
between 1 and 5). Each segment that completes is immediately merged into the in-memory bilingual
map and rendered in Reader without waiting for the remaining segments.

### 3.2 Progressive rendering

As each segment completes, the Reader view updates in place:
- Completed segments show the translation block immediately.
- Pending segments show a neutral placeholder (e.g., a subtle loading indicator or blank block).
- No visual reflow of the article structure; only the translation block for the completed segment
  appears.

The user sees the first translated paragraph within seconds of starting a run, even for long
articles.

### 3.3 Failure isolation

Because each segment is an independent request:
- A failed or timed-out segment can be retried independently without affecting others.
- A segment failure does not invalidate segments that already succeeded.
- Failed segments render as `No translation` with retry affordances (inline per-segment retry and
  a banner-level retry action for all failed segments).
- The run is considered successful when at least one segment translation succeeds.
- The run is considered failed only when zero segments succeed.

This eliminates the all-or-nothing failure mode of the current batch approach.

### 3.4 Universal model compatibility

The per-segment prompt makes no structural demands. Any model capable of translating a paragraph
is compatible: general-purpose models, MT-specialized models (e.g., Hunyuan MT 1.5), local models.
Users who want fast, low-cost translation can configure a MT-specialized model and get lower
latency than any batch-JSON approach could offer.

---

## 4. Design Decisions

### 4.1 No adaptive mode switching

The per-segment approach is the single execution mode for all article lengths. There is no
threshold below which a batch approach is activated. This decision rests on three independent
arguments.

**a. Segment alignment is a structural problem in any batch approach.**

Mercury renders translation bilingually, with each translated block positioned immediately after
its source segment. This requires a precise one-to-one mapping between source segments and
translation units. In any batch approach — whether whole-article or chunked — the model receives
multiple paragraphs and is expected to produce an aligned output. Even with careful prompting, a
model may merge two short paragraphs into one, split a long paragraph into two, or restructure
lists and headings. The current implementation addresses this by requiring `sourceSegmentId`-keyed
JSON output and running multi-stage parse-and-repair pipelines. These mechanisms reduce but do not
eliminate misalignment risk, and they add significant implementation complexity.

In the per-segment approach, misalignment is impossible by construction: each request carries
exactly one segment and the response is unconditionally associated with that segment. No ID
matching, JSON parsing, coverage validation, or repair pipeline is necessary.

**b. Latency and round-trip time favor per-segment even for short articles.**

For a 3-segment article, three concurrent per-segment requests complete in one round-trip. A
single batch request for the same article requires the same round-trip plus JSON serialization,
parse overhead, and failure-recovery overhead on any parse error. The batch approach is not faster;
it is structurally more fragile for the same wall-clock duration.

**c. Cost and rate-limit impact are acceptable and manageable.**

Per-segment requests repeat the system prompt on every call. For a 30-segment article, this adds
approximately 100 tokens × 30 = 3,000 extra input tokens compared to a single batch request.
However, the batch approach carries its own overhead: JSON structure, segment ID tokens, and
structured-output enforcement add a comparable amount in both input and output. In practice the
total token count difference between the two approaches is within ±15% — negligible for typical
per-token pricing.

Rate-limit (RPM) pressure is higher for per-segment requests. For providers with tight RPM limits
(e.g., Claude or DeepSeek at entry tiers, typically 50–60 RPM), a 30-segment article at concurrency
3 can approach the limit if individual requests are very fast. This is addressed by two mechanisms
that are independent of execution model choice:

- The concurrency degree is user-configurable (1–5). Users on constrained provider tiers can lower
  concurrency to 1 or 2 without changing the execution model.
- In the current scope, HTTP `429` is handled fail-fast (no automatic retry): the request fails
  immediately, surfaced to the user, and users can reduce concurrency / switch model / check
  provider quotas before retrying manually.

Batch approaches do not avoid RPM pressure; they trade many small requests for fewer large ones,
which shifts pressure to TPM (tokens per minute) limits instead. Neither approach is categorically
friendlier to rate limits; the difference is in which limit dimension is stressed.

Adaptive mode switching would preserve the alignment risk, the parse/repair pipeline, and the
two-code-path maintenance burden of the batch approach for no meaningful user-visible benefit.
The batch approaches are removed, not conditionally preserved.

### 4.2 Single model configuration — no two-model problem

Because the per-segment prompt imposes no structural requirements, there is no need for a separate
model configuration per execution mode. The existing two-slot configuration (Primary Model,
Fallback Model) is sufficient and unchanged. The Fallback Model is used when the primary model
fails or is unavailable for a given segment, not for a different execution mode.

Users who previously configured a capable model for JSON output can keep it. Users who want to
switch to a fast MT-specialized model can do so without any settings redesign.

### 4.3 Concurrency policy

Default concurrency: **3 parallel segment requests**.

Concurrency is surfaced in Translation settings as an integer control (range 1–5). The default of
3 is conservative enough to avoid rate-limit pressure on most providers while delivering
progressive rendering within a few seconds for typical articles.

### 4.4 Context continuity across segment boundaries

For translation consistency, each request optionally carries the preceding segment's source text
as a read-only context hint. It is injected into the user message and not expected in the response:

```
Context (preceding paragraph, do not translate):
{previousSourceText}

Translate the following text to {targetLanguage}. Output the translation only.

{sourceText}
```

This is the default prompt template behavior. It has no effect on response parsing since the
response is plain text.

### 4.5 Per-segment retry policy

Each segment request uses a fixed two-step automatic route policy:
- One attempt on the primary route.
- If the primary attempt fails and a fallback route is configured, one attempt on fallback.

There is no `skipped` state. A segment ends as either:
- `success`: a non-empty translated text was produced.
- `failure`: all automatic route attempts failed or returned invalid/empty output.

Automatic retries are intentionally bounded. Additional retries are explicit user actions:
- Retry one failed segment from its inline retry control.
- Retry all failed segments from the reader banner secondary action.

Retries for one segment do not block concurrent requests for other segments.

### 4.6 Terminal semantics and cancellation UX

**Run success/failure and persistence**

- Segment-level outcomes are binary (`success` / `failure`).
- Run-level success: at least one segment succeeds.
- Run-level failure: zero segments succeed.
- On run-level success, persist only successful segments.
- On run-level failure, persist nothing.

**Failure surfacing**

- Failed segments render `No translation` in-place.
- Each failed segment provides an inline retry action.
- Reader banner shows a partial-failure message with secondary action: `Retry failed segments`.
- Banner/debug issue reporting stays on the existing unified path (Reader banner + Debug Issues).

**Cancel semantics**

- User cancellation never counts as success by itself.
- Cancellation stops all pending/unfinished segment tasks.
- If cancellation occurs with zero successful segments, Reader returns to original mode.
- If cancellation occurs with at least one successful segment, Reader stays in bilingual mode and
  unresolved segments render `No translation` with retry controls.

**Translation button state**

- Default: `Translate`.
- If persisted/available translation is shown: button toggles to `Return to Original`.
- If translation run starts with no available translation payload: button switches to
  `Cancel Translation`.
- On cancellation:
  - zero translated segments => return to original state;
  - non-zero translated segments => remain bilingual with retry controls for unresolved segments.

---

## 5. Data Migration

### 5.1 Current schema (verified)

The production database contains two translation tables:

**`translation_result`** (one row per successfully completed translation run for a slot):

| Column | Type | Notes |
|---|---|---|
| `taskRunId` | INTEGER PK | FK → `agent_task_run.id` (cascade delete) |
| `entryId` | INTEGER | FK → `entry.id` (cascade delete) |
| `targetLanguage` | TEXT | normalized language code |
| `sourceContentHash` | TEXT | hash of source content |
| `segmenterVersion` | TEXT | currently `"v1"` for all rows |
| `outputLanguage` | TEXT | |
| `createdAt` | DATETIME | |
| `updatedAt` | DATETIME | |

Unique index: `(entryId, targetLanguage, sourceContentHash, segmenterVersion)` — this is the slot
identity key. `translation_result` holds no prompt version; that lives in `agent_task_run`.

**`translation_segment`** (one row per translated segment within a run):

| Column | Type | Notes |
|---|---|---|
| `taskRunId` | INTEGER | FK → `translation_result.taskRunId` (cascade delete) |
| `sourceSegmentId` | TEXT | opaque stable ID, e.g. `"seg-a3f2"` |
| `orderIndex` | INTEGER | render order |
| `sourceTextSnapshot` | TEXT (nullable) | diagnostic provenance |
| `translatedText` | TEXT | the translation |
| `createdAt` | DATETIME | |
| `updatedAt` | DATETIME | |

Unique index on `(taskRunId, sourceSegmentId)`. Ordered index on `(taskRunId, orderIndex)`.

**`agent_task_run`** carries diagnostic provenance per run: `templateId`, `templateVersion`,
`promptVersion`, `runtimeParameterSnapshot`, `status` (`succeeded` / `failed` / `timedOut` /
`cancelled` / `queued` / `running`).

As of the current production database: 27 `translation_result` rows, 406 `translation_segment`
rows, all with `segmenterVersion = "v1"`.

### 5.2 Schema compatibility

The per-segment approach produces segment rows with identical column layout:
- One `translation_segment` row per successfully translated source segment, keyed by
  `sourceSegmentId`.
- `orderIndex` and `sourceTextSnapshot` are populated by the same extractor path.
- `translatedText` is the plain-text response from the model request for that segment.

**No schema migration is required for Phases 1–3.** The existing `persistSuccessfulTranslationResult`
write path in `AppModel+TranslationStorage.swift` remains valid without modification: it still
receives a non-empty `[TranslationPersistedSegmentInput]` array at terminal success and writes it
atomically. Under the frozen terminal contract, that array may be a strict subset of source
segments (partial-success persistence).

### 5.3 Prompt template versioning

The built-in prompt template (`Resources/Agent/Prompts/translation.default.yaml`) is currently at
version `v2`. The per-segment template will be `v3`. The version is recorded in the
`agent_task_run.templateVersion` field of each run — it is diagnostic provenance, not a cache
invalidation key. Existing rows (recorded under the old template) continue to render correctly
because the output they produced — `translation_segment` rows keyed by `sourceSegmentId` — has
identical structure regardless of which prompt version was used to generate it.

Sandbox override files (`translation.yaml` in the app container) created by users from the `v2`
template may stop working once the required-placeholder set changes. Phase 0 explicitly requires
fallback-to-built-in behavior when sandbox parsing/validation fails. After that alignment lands,
users will receive built-in `v3` behavior automatically until they manually update their sandbox
file.

### 5.4 No user-visible data loss

Existing translated articles render from persisted `translation_segment` rows; the rendering path
(`TranslationBilingualComposer.compose`) reads only `sourceSegmentId` → `translatedText` from the
map. This map is assembled the same way regardless of whether the rows were produced by the old
batch approach or the new per-segment approach.

### 5.5 Phase 4 schema addition (post-1.0)

Checkpoint persistence requires the ability to write partial `translation_segment` rows during an
in-flight run, before terminal success. This needs one additive schema change:

```sql
-- new migration: `addTranslationResultStatus`
ALTER TABLE translation_result ADD COLUMN runStatus TEXT NOT NULL DEFAULT 'succeeded';
```

Existing rows default to `"succeeded"`. In-progress rows are inserted with `runStatus = "running"`
at run start, updated to `"succeeded"` at terminal success, or deleted on failure/cancellation.
The slot uniqueness constraint remains on `(entryId, targetLanguage, sourceContentHash,
segmenterVersion)`, so at most one row per slot exists at any time (in-progress or succeeded).

---

## 6. Implementation Plan

### Phase 0 — Alignment debt paydown (must land before Phase 1)

This phase closes known document-vs-implementation gaps so that Phase 1 can be executed without
hidden contract breaks.

**0.1 Prompt customization fallback behavior**

Current implementation loads sandbox `translation.yaml` first and fails hard if the file is invalid.
It does **not** currently fallback to the built-in template on parse/validation failure.

Required change:
- Update `TranslationPromptCustomization.loadTranslationTemplate` to:
  1. Try sandbox template first.
  2. If sandbox file exists but is invalid, record a debug issue and fallback to built-in template.
  3. Keep sandbox file on disk unchanged (do not overwrite user edits).

Acceptance criteria:
- Corrupted sandbox `translation.yaml` no longer blocks translation runs.
- Built-in template is used automatically when sandbox template fails to load.

**0.2 Template syntax compatibility for `v3`**

Frozen decision: keep the current simple placeholder renderer. Do not add section syntax.

Required change:
- Keep `translation.default@v3` free of section blocks.
- Inject optional `previousSourceText` in request assembly code when present.

Acceptance criteria:
- `translation.default@v3` loads successfully with strict validation.
- When `previousSourceText` is absent, no dangling markers appear in prompts.
- `AgentPromptTemplateStore` remains direct-placeholder replacement only.

**0.3 Terminal semantics for partial success (no `skipped` state)**

Frozen decision:
- Segment outcomes are binary: `success` or `failure`.
- Automatic attempt policy: one primary-route attempt, then one fallback-route attempt (if fallback
  exists).
- No `skipped` state is introduced.
- Run succeeds when at least one segment succeeds.
- Run fails when zero segments succeed.
- On success, persist only successful segments; failed segments render `No translation`.

Acceptance criteria:
- `runPerSegmentExecution` terminal rule is unambiguous and test-covered.
- Storage write-path invariants match partial-success persistence.
- Reader renders failed segments with retry affordances.

**0.4 Rate-limit handling realism (HTTP 429)**

For the current milestone, `429` handling is explicitly fail-fast. Automatic retry/backoff is
deferred and out of scope.

Required change:
- Classify HTTP `429` as immediate request failure for this run path (no in-process auto retry).
- Surface clear user guidance in Reader banner / diagnostics:
  - rate limit reached;
  - suggested user actions: reduce translation concurrency, switch model/provider tier, retry later.
- Keep this behavior isolated and explicit so a future adaptive retry policy can be introduced
  behind a separate design decision.

Acceptance criteria:
- Reproducible `429` responses fail immediately without hidden automatic retries.
- User-facing message and debug trace clearly indicate rate-limit failure and suggested actions.

**0.5 Progressive-render failure policy consistency**

Frozen decision:
- Retain already-rendered successful segments on failure/cancellation.
- Do not discard partial map immediately.
- On cancellation:
  - no successful segments => return to original mode;
  - one or more successful segments => remain bilingual.

Acceptance criteria:
- Failure/cancellation behavior is consistent across execution, projection/runtime state, and
  Reader rendering.
- Dedicated tests verify both cancellation branches (zero-success vs non-zero-success).

**0.6 Runtime metadata consistency**

Failure/cancellation recording must use the actual loaded translation template metadata, not stale
hardcoded values.

Required change:
- Ensure terminal/failure diagnostic paths record the same `templateId`/`templateVersion` that the
  execution path used.

Acceptance criteria:
- `agent_task_run` rows for translation failures/cancellations report the correct template metadata.

---

### Phase 1 — Per-segment execution core

**Target file: `AppModel+TranslationExecution.swift`**

Prerequisite:
- `Phase 0` is completed and the terminal contract from `0.3` is frozen.

Delete entirely:
- `TranslationExecutionSupport.chooseStrategy`
- `TranslationExecutionSupport.chunks`
- `TranslationExecutionSupport.tokenAwareChunks`
- `TranslationExecutionSupport.sourceSegmentsJSON`
- `TranslationExecutionSupport.estimatedTokenCount`
- `TranslationExecutionSupport.parseTranslatedSegments`
- `TranslationExecutionSupport.parseTranslatedSegmentsRecovering`
- `executeStrategyA`
- `executeStrategyC` and `ChunkExecutionResult`
- `parseTranslatedSegmentsWithRepair`
- `fillMissingSegmentsIfNeeded`
- `performTranslationMissingSegmentCompletionRequest`
- `performTranslationOutputRepairRequest`
- `shouldAttemptTranslationOutputRepair`
- `validateCompleteCoverage`
- All JSON extraction helpers (`extractJSONPayload`, `extractCodeFenceJSON`, `recoverSegmentMapFromLooseText`, etc.)

Keep and simplify:
- `performTranslationModelRequest`: remove the JSON prompt suffix and `sourceSegmentsJSON`
  parameter; add `sourceText: String` and optional `previousSourceText: String?` parameters.
  Response is now plain text — no parsing, just `.text` from `LLMResponse`.
- Route resolution and candidate enumeration: unchanged.
- Usage event recording: unchanged, add `requestPhase: .normal` for all segment requests.
- `TranslationExecutionSupport.buildPersistedSegments`: behavior follows the `Phase 0.3` frozen
  terminal contract (partial success allowed, non-empty subset required).

Add new:
- `runPerSegmentExecution(...)`: replaces `runTranslationExecution`. Uses `withTaskGroup` with
  a semaphore / async slot pool enforcing `concurrencyDegree` concurrent segment requests.
  Each task translates one segment using one primary attempt + one fallback attempt (if configured).
  On attempt exhaustion, mark the segment as failed. On success, call `onSegmentCompleted`.
- `onSegmentCompleted` callback: emits `TranslationRunEvent.segmentCompleted` immediately.
- Failed segment tracking (`failedSegmentIDs`) for post-run rendering and retry actions.

Modify `TranslationRunEvent`:
- Remove `.strategySelected`
- Add `.segmentCompleted(sourceSegmentId: String, translatedText: String)`

Modify `TranslationExecutionSuccess`:
- Remove `strategy`, `requestCount`
- Keep `translatedSegments`, `failedSegmentIDs`, `providerProfileId`, `modelProfileId`,
  `templateId`, `templateVersion`, `runtimeSnapshot`

**Target file: `TranslationContracts.swift`**

- Remove `wholeArticleSingleRequest` and `chunkedRequests` cases from `TranslationRequestStrategy`
  (keep `perSegmentRequests` as the only value, or remove the enum if it becomes a single case
  with no branching logic).
- Remove `TranslationThresholds` struct and `TranslationThresholds.v1`.
- Remove `TranslationPolicy.defaultStrategy`, `fallbackStrategy`, `enabledStrategiesForV1`,
  `deferredStrategiesForV1`.
- Add `Agent.Translation.concurrencyDegree` `UserDefaults` key constant.
- Add `concurrencyDegree: Int` to `TranslationAgentDefaults` with a safe default of 3.

**Target file: `Resources/Agent/Prompts/translation.default.yaml`**

Replace with `v3` template (simple placeholder syntax only):

```yaml
id: translation.default
version: v3
taskType: translation
requiredPlaceholders:
  - targetLanguageDisplayName
  - sourceText
systemTemplate: |
  You are a professional translator.
  Translate the given text faithfully into {{targetLanguageDisplayName}}.
  Output the translation only — no explanation, no preamble, no formatting marks.
template: |
  Translate the following text into {{targetLanguageDisplayName}}. Output the translation only.

  {{sourceText}}
```

Optional `previousSourceText` context is injected in request assembly code (not in template syntax
or placeholder lists).

Acceptance criteria:
- A 60-segment article completes without execution timeout.
- `TranslationThresholds`, `chooseStrategy`, and all JSON parse/repair code are deleted.
- `translation.default.yaml` version is `v3`.

**Tests to update:**
- `TranslationContractsTests`: remove threshold assertions; add concurrency degree default test.
- `TranslationExecutionSupportTests`: remove chunking and JSON parse tests; add per-segment
  retry-path unit tests.
- `TranslationSchemaTests`: no changes needed.
- `TranslationStoragePersistenceTests`: no changes needed (storage path is unchanged).

---

### Phase 2 — Progressive rendering

**Target file: `AppModel+TranslationExecution.swift`**

- In `startTranslationRun`, handle the new `.segmentCompleted` event from the execution task and
  forward it through the public `onEvent` callback.
- The public `TranslationRunEvent` enum now includes `.segmentCompleted(sourceSegmentId: String,
  translatedText: String)`.

**Target file: `AgentRuntimeProjection.swift`**

- Add `partialTranslatedSegments: [String: String]` to the translation projection state.
- On `.segmentCompleted`, merge the new segment into `partialTranslatedSegments` and mark the
  projection as dirty to trigger a view update.
- On terminal success, the in-memory map is superseded by the persisted map loaded via
  `loadTranslationRecord`; on failure/cancellation, behavior follows the `Phase 0.5` frozen policy.

**Target file: `ReaderDetailView.swift` (or its translation sub-coordinator)**

- Observe `partialTranslatedSegments` and `failedSegmentIDs` for the active run.
- During an active run, call `TranslationBilingualComposer.compose(...)` with loading placeholders
  for pending segments.
- After terminal success/failure/cancellation, render unresolved segments as `No translation` with:
  - inline per-segment retry action; and
  - banner-level `Retry failed segments` secondary action.
- Extend `TranslationBilingualComposer` to render segment-specific missing/failure blocks with
  actionable metadata (segment ID) for retry handling.
- Throttle re-composition to avoid redundant DOM patching if multiple segments complete in the
  same run-loop cycle (coalesce on a short debounce, e.g. 50 ms).
- Implement translation toolbar/button state machine: `Translate` / `Cancel Translation` /
  `Return to Original` per frozen `4.6` semantics.
- Add Reader action bridge for retry controls using a custom internal URL scheme:
  - Embed links in translation blocks, e.g.
    - `mercury-action://translation/retry-segment?entryId=...&slot=...&segmentId=...`
    - `mercury-action://translation/retry-failed?entryId=...&slot=...`
  - Intercept in `WKNavigationDelegate.decidePolicyFor` and cancel navigation.
  - Validate action context (`entryId`, slot key, optional run/session token) before executing.
  - Dispatch to typed Swift handlers (`retrySegment`, `retryFailedSegments`) on `MainActor`.

Acceptance criteria:
- Press Translate on a 30-segment article: first translated paragraph appears within one request
  round-trip.
- Bilingual view fills progressively with no full document reload.
- On terminal success, persisted segments match successful segment outputs (partial success
  allowed).
- On failure or cancellation, rendered partial behavior exactly matches the `Phase 0.5` frozen
  policy.
- Failed segments expose both inline retry and banner-level retry-all-failed actions.

---

### Phase 3 — Settings and model configuration

**Target file: `AgentSettingsView.swift` (or equivalent translation settings subview)**

- Add an integer stepper labeled "Concurrency" (range 1–5, default 3) to the Translation settings
  panel.
- Bind to `UserDefaults` key `Agent.Translation.concurrencyDegree`.
- Add a brief caption: "Number of paragraphs translated in parallel. Lower values reduce
  rate-limit pressure."

**Target file: `TranslationContracts.swift`**

- `TranslationAgentDefaults.concurrencyDegree` reads from `UserDefaults.standard.integer(forKey:
  "Agent.Translation.concurrencyDegree")`, clamped to `1...5`, defaulting to 3.

**Target file: any view or debug panel referencing strategy or threshold**

- Remove all references to `TranslationRequestStrategy.wholeArticleSingleRequest`,
  `chunkedRequests`, and `TranslationThresholds` that were carried into runtime snapshots or
  debug displays. Update `runtimeParameterSnapshot` keys in `runPerSegmentExecution` to reflect
  the new execution model (e.g. `concurrencyDegree`, `segmentCount`, `failedSegmentCount`).

Acceptance criteria:
- Concurrency stepper is visible in Translation settings.
- `UserDefaults` key is read at run start; changing it takes effect on the next run.
- No strategy or threshold reference appears in runtime snapshots, runtime traces, or settings UI.

---

### Phase 4 — Checkpoint persistence (post-1.0, optional)

**New DB migration: `"addTranslationResultStatus"`**

```swift
migrator.registerMigration("addTranslationResultStatus") { db in
    let columns = try db.columns(in: TranslationResult.databaseTableName).map(\.name)
    guard columns.contains("runStatus") == false else { return }
    try db.alter(table: TranslationResult.databaseTableName) { t in
        t.add(column: "runStatus", .text).notNull().defaults(to: "succeeded")
    }
}
```

**Write path changes (`AppModel+TranslationStorage.swift`)**

- Add `startTranslationRunForCheckpoint(...)`: inserts an `agent_task_run` with `status = .running`
  and a corresponding `translation_result` row with `runStatus = "running"`. Returns the `taskRunId`
  for the in-progress run.
- Add `persistTranslationSegmentCheckpoint(taskRunId:segment:)`: upserts one `translation_segment`
  row under the in-progress `taskRunId`.
- Modify `persistSuccessfulTranslationResult`: if a `running` row already exists for the slot,
  update it to `runStatus = "succeeded"` and update `agent_task_run.status` in the same
  transaction rather than inserting a new run.
- On failure/cancellation: delete the `running` row and its associated segments (existing cascade
  delete handles the segment cleanup).

**Read path changes (`AppModel+TranslationStorage.swift`)**

- `loadTranslationRecord`: if the most recent row has `runStatus = "running"` and the associated
  `agent_task_run.status` is not `running` (e.g. process was killed), treat it as an orphaned
  partial record. Surface it as a partially translated result with a resume prompt, or delete it
  on next run start.

**Entry activation path**

- On entry activation with `targetLanguage`, check for an in-progress (non-terminal) row for the
  slot. If one exists, load its partial segment map immediately and render the bilingual view with
  available translations plus placeholders. Offer a "Resume translation" action in place of the
  standard "Translate" trigger.

Acceptance criteria:
- Entry switch during an active run preserves the already-translated segments across reopen.
- Orphaned `running` rows (from a crash) are detected and handled gracefully on next activation.
- `succeeded` indicates at least one segment translated (result may be partial).

---

## 7. Acceptance Criteria

- A 100-segment article running against a fast MT-specialized model produces the first visible
  translated paragraph within 3 seconds of the run starting.
- The execution timeout rate for articles under 200 segments drops to near zero on any provider
  that responds within normal per-request timeouts.
- A single segment failure does not block or fail the rest of the article.
- Run-level success allows partial persistence (at least one translated segment).
- Failed segments render `No translation` with inline retry and banner-level retry-all action.
- No JSON parsing logic, repair requests, or missing-segment completion requests exist in the
  codebase after Phase 1.
- Existing v1 translated articles continue to render correctly from persisted data without
  re-translation.
- Translation settings expose one model selector (Primary) and one optional selector (Fallback),
  unchanged from the current layout.

---

## 8. Execution Checklist (Tracking)

Legend: `[ ]` not started, `[~]` in progress, `[x]` done, `[!]` blocked

### 8.1 Decision gates (must freeze before Phase 1)

- [x] Freeze `Phase 0.2` template syntax path (simple placeholder syntax only; optional context injected in request assembly).
- [x] Freeze `Phase 0.3` terminal semantics (no `skipped` state; run succeeds if at least one segment succeeds).
- [x] Freeze `Phase 0.5` failure/cancellation partial-render policy (retain successful partial output; cancel branch by zero/non-zero success).
- [x] Freeze `429` handling policy for current milestone (fail-fast, no automatic retry).

### 8.2 Phase 0 — Alignment debt paydown

- [ ] Implement sandbox `translation.yaml` invalid-file fallback to built-in template with debug issue logging.
- [ ] Deliver template compatibility for `v3` under the frozen `0.2` decision.
- [ ] Align terminal semantics implementation with the frozen `0.3` contract and add tests.
- [ ] Implement explicit `429` fail-fast handling and user guidance surfacing (banner + trace).
- [ ] Align progressive-render failure/cancellation behavior with frozen `0.5` policy and add tests.
- [ ] Ensure failure/cancellation run metadata uses the actual loaded translation template ID/version.

### 8.3 Phase 1 — Per-segment execution core

- [ ] Remove strategy A/C selection and all threshold/chunking decision paths.
- [ ] Remove JSON parse/repair/missing-completion pipeline end to end.
- [ ] Replace translation execution with bounded-concurrency per-segment requests.
- [ ] Add per-segment retry policy (primary once + fallback once) and failed-segment tracking.
- [ ] Update `TranslationRunEvent` (`.segmentCompleted` added, `.strategySelected` removed).
- [ ] Update runtime snapshot fields for the new execution model.
- [ ] Upgrade `translation.default.yaml` to `v3`.
- [ ] Update unit tests (`TranslationContractsTests`, `TranslationExecutionSupportTests`) for new semantics.

### 8.4 Phase 2 — Progressive rendering

- [ ] Wire `.segmentCompleted` events from execution to Reader translation presentation path.
- [ ] Maintain and merge in-memory partial segment map during active run.
- [ ] Re-compose bilingual HTML incrementally with short coalescing debounce.
- [ ] Render failed segments with `No translation` + inline per-segment retry control.
- [ ] Add banner secondary action: `Retry failed segments`.
- [ ] Implement toolbar/button state machine: `Translate` / `Cancel Translation` / `Return to Original`.
- [ ] Verify terminal success handoff to persisted record rendering.
- [ ] Verify failure/cancellation behavior matches frozen `0.5` policy.

### 8.5 Phase 3 — Settings and model configuration

- [ ] Add Translation Concurrency setting (range `1...5`, default `3`) in Agent settings UI.
- [ ] Persist/load `Agent.Translation.concurrencyDegree` with clamping and defaulting.
- [ ] Remove strategy/threshold references from settings, traces, and runtime snapshots.
- [ ] Update settings/runtime tests to cover concurrency persistence and application.

### 8.6 Phase 4 — Checkpoint persistence (post-1.0, optional)

- [ ] Add migration `addTranslationResultStatus` (`translation_result.runStatus`).
- [ ] Add in-progress run row creation + per-segment checkpoint upsert path.
- [ ] Finalize running rows to `succeeded` on success; cleanup running rows on failure/cancel.
- [ ] Add orphaned running-row detection and resume/cleanup behavior on next activation.
- [ ] Add tests for crash-resume and orphan cleanup flows.

### 8.7 Final verification and rollout gates

- [ ] Run `./scripts/build` clean (no warnings/errors).
- [ ] Pre-UAT phase gate: before full user testing, each phase is validated by code review + unit
  tests + phase-local smoke verification.
- [ ] Functional E2E smoke gate: after Phase 2, verify progressive rendering, retry controls, and
  cancel semantics end-to-end in-app.
- [ ] Full user testing (UAT) gate: start only after Phase 3 is complete (including settings and
  runtime snapshot cleanup), with a clean build.
- [ ] Validate first-visible-segment latency target on long article sample.
- [ ] Validate reduced timeout rate on representative provider set.
- [ ] Validate compatibility: legacy `v1` persisted translations still render correctly.
