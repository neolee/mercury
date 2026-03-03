# Tags System v2 Technical Contracts (Blueprint)

> Date: 2026-03-01 (revised 2026-03-03)
> Status: Active
> Audience: Developers, AI Coding Agents
> Scope: Hard technical constraints for implementing `tags-v2.md`

This document defines the strict, non-negotiable coding contracts to guarantee that the Tags System integrates safely into Mercury's Swift/macOS/GRDB architecture without violating existing policies.

---

## 1. Data Store Contracts (GRDB)

### 1.1 Model Naming and Conformances
All models must live in `Mercury/Core/Database/Models.swift` (or a dedicated `Models+Tags.swift` if preferred). Let's keep it simple: `Tag`, `TagAlias`, and `EntryTag`.

**Required Definitions:**
```swift
struct Tag: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "tag"
    
    var id: Int64?
    var name: String
    var normalizedName: String
    var isProvisional: Bool
    var usageCount: Int
    // ...
}

struct TagAlias: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "tag_alias"
    
    var id: Int64?
    var tagId: Int64
    var alias: String
    var normalizedAlias: String
}

struct EntryTag: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "entry_tag"
    
    var entryId: Int64
    var tagId: Int64
    var source: String // e.g. "rss", "nlp", "ai", "manual"
    var confidence: Double?
}
```

### 1.2 GRDB Associations
In `Models.swift`, establish the relationship so `Entry` can fetch `tags` cleanly:
```swift
extension Entry {
    static let entryTags = hasMany(EntryTag.self)
    static let tags = hasMany(Tag.self, through: entryTags, using: EntryTag.tag)
}

extension Tag {
    static let entryTags = hasMany(EntryTag.self)
    static let entries = hasMany(Entry.self, through: entryTags, using: EntryTag.entry)
    static let aliases = hasMany(TagAlias.self)
}

extension EntryTag {
    static let entry = belongsTo(Entry.self)
    static let tag = belongsTo(Tag.self)
}
```

### 1.3 Transaction Boundary Requirements
Tag assignment is a multi-step mutation (check for tag -> update/insert tag -> insert `entry_tag` -> calculate `isProvisional`). 
**DO NOT use multiple UI calls.** These MUST occur inside a central `db.write { db in ... }` transaction within a dedicated method `EntryStore.assignTags(to entryId: Int64, names: [String], source: String)`.

---

## 2. Navigation & UI State Boundaries

### 2.1 Navigation Root
Keep navigation changes within the existing `FeedSelection`-driven path (ContentView selection + query token flow), and add a tag selection branch there.
Do not introduce a broad global `NavigationState` refactor during this phase.

### 2.2 EntryListQuery Extension
Filtering happens directly in `EntryStore.EntryListQuery` and `makeEntryQueryToken(...)`.
Add:
```swift
public var tagIds: Set<Int64>?
public var tagMatchMode: TagMatchMode = .any
```

### 2.3 Batch Actions Consistency
Batch actions (*Mark All as Read*) currently respect `feed scope + unread filter + search filter`. 
**Requirement:** `Tag Filter` MUST be appended to `MarkReadPolicy` contexts to ensure "Mark All as Read" inside a Tag view only marks entries associated with that tag, strictly respecting the query.

---

## 3. NLP and Execution Constraints

### 3.1 NLTagger Execution thread
Apple's `NLTagger` is fully synchronous.
**Contract:** The `NaturalLanguage` execution code must be wrapped in an `async` function and executed off the `MainActor` (e.g., using a background `actor LocalTaggingService { ... }` or `Task.detached`). DO NOT invoke `NLTagger.enumerateTags(...)` inside View `.task {}` modifiers or `@MainActor` closures.

### 3.2 Parsing Timing
- `Local NLP Pass (NLTagger)`: Triggered on-demand when the tagging panel opens. Not scheduled passively or on sync, to avoid blocking thread contention with large unread queues.

---

## 4. Tagging Agent Architecture

The tagging agent has two distinct execution modes with different scheduling strategies. Both share the same route resolution and LLM provider infrastructure.

### 4.1 Two Execution Modes

Panel and batch use **separate task kinds** so they can have independent rate limits, timeouts, and concurrency policies (see §4.8 for the required code changes).

| Mode | Task kinds | Trigger | Scheduling | Output destination |
|---|---|---|---|---|
| **Panel (on-demand)** | `AgentTaskKind.tagging` / `AppTaskKind.tagging` | User opens tagging panel | `TaskQueue`, replace-on-reopen policy (see §4.2) | `@State` in `ReaderTaggingPanelView`; nothing written until user accepts |
| **Batch** | `AgentTaskKind.taggingBatch` / `AppTaskKind.taggingBatch` | User confirms batch run in Settings | `TaskQueue`, runs as background task; per-entry concurrency is internal (see §4.5) | `entry_tag` rows (provisional), pending sign-off |

Both modes share the **same underlying infrastructure**: `resolveAgentRouteCandidates`, `AgentLLMProvider`, `AgentFailureClassifier`, usage telemetry, and error classification. `AgentTaskType.tagging` (the DB-level type used in `AgentTaskRun` records) is shared by both modes — the `AgentTaskKind.taggingBatch` distinction exists only at the `TaskQueue` / scheduling layer.

### 4.2 Panel Mode: Scheduling Policy

Panel tagging uses the same `TaskQueue` + `AppModel+TagExecution.swift` infrastructure as batch. The difference is the **scheduling policy** chosen for the panel context.

**Panel scheduling policy (one option — not an architectural constraint):**
- Owner: `AgentRunOwner(taskKind: .tagging, entryId: entry.id, slotKey: "panel")`.
- **Replace-on-reopen:** if a panel task for this owner is already active when a new one is submitted (e.g. user closes and reopens the panel quickly), cancel the active task and submit the new one immediately. No waiting slot.
- This differs from Summary (`active = 1 + waiting = 1`, latest-only replacement). The rationale: queueing a panel suggestion request across distinct user open/close events provides no value — a stale result from a previous open would be confusing. However, this is a policy choice made at the call site (`AppModel+TagExecution.swift`), not a constraint of the underlying `TaskQueue` or `AgentRunStateMachine`.

**Execution contract:**
1. `ReaderTaggingPanelView` observes `AgentRuntimeStore` for the tagging task state of the current entry.
2. On `.onAppear`, `NLTagger` runs first (synchronous via `LocalTaggingService`) — suggestions appear immediately.
3. If `appModel.isTaggingAgentAvailable`, call `appModel.startTaggingRun(for: entry, mode: .panel)`. The panel shows a loading indicator while state is `.requesting` or `.generating`.
4. On `.completed`: replace `nlpSuggestions` with the resolved tag names from the run result.
5. On `.failed` / `.cancelled`: silently retain NLTagger results. Do not show an error in the panel.
6. On `.onDisappear` or entry identity change: cancel the active panel task via `appModel.cancelTaggingRun(for: entry, slotKey: "panel")`.

**Non-streaming execution** (`AppModel+TagExecution.swift` internals for panel mode):
- Call `resolveAgentRouteCandidates(taskType: .tagging, ...)`.
- Build `LLMRequest` with `stream: false`; inject prompt template variables.
- Call `AgentLLMProvider.complete(request:)` with `panelLLMTimeoutSeconds` deadline.
- Parse response as flat `[String]` JSON (see §6.1). On parse failure: log debug issue, return `[]`.
- Run each name through alias resolver + DB strict match.
- Write usage telemetry. Persist a `AgentTaskRun` record (same as Summary).
- Failures (`.noModelRoute`, network, parse): caught by the standard `AgentRuntimeEngine` error path and classified by `AgentFailureClassifier`. `FailurePolicy.shouldSurfaceFailureToUser(kind: .tagging)` returns `false`; panel fallback to NLTagger is silent.

### 4.3 `supportsTagging` Field Policy

`AgentModelProfile.supportsTagging` defaults to `false` in the DB migration but is written as `true` for every model created via `AppModel+AgentModels.swift`. The field is not exposed in UI settings. This matches the existing behavior of `supportsSummary` and `supportsTranslation`. Never add UI toggles for per-model capability flags in v2.

### 4.4 `TaggingAgentDefaults` and Availability

Add a `TaggingAgentDefaults` struct and UserDefaults-backed load/save (analogous to `SummaryAgentDefaults`):

```swift
struct TaggingAgentDefaults: Sendable {
    var primaryModelId: Int64?
    var fallbackModelId: Int64?
}
// UserDefaults keys:
// "Agent.Tagging.PrimaryModelId"
// "Agent.Tagging.FallbackModelId"
```

Fix `checkAgentAvailability(for: .tagging)`: replace the hardcoded `return false` with the same logic as `.summary` — read UserDefaults model IDs, query `supportsTagging == true && isEnabled && !isArchived` models, verify at least one has an enabled provider. Add `@Published var isTaggingAgentAvailable: Bool` to `AppModel` and update `refreshAgentAvailability()`.

### 4.5 Batch Mode: TaskQueue Integration

Batch tagging enqueues a **single outer task** with `AgentTaskKind.taggingBatch` / `AppTaskKind.taggingBatch`. The outer task runs as a background operation: it can coexist with a panel tagging task (`.tagging`) in flight at the same time. Per-entry LLM calls are driven internally by the outer task with bounded concurrency — they do NOT each produce a separate `AppTask` entry.

- `AgentRuntimePolicy.perTaskConcurrencyLimit[.taggingBatch] = 1`: only one batch run in flight at a time.
- `AgentRuntimePolicy.perTaskWaitingLimit[.taggingBatch] = 0`: a second batch request while one is running is rejected (not queued). The Settings UI prevents this via the `tag_batch_run.status = 'running'` guard.
- Internal per-entry parallelism is controlled by `BatchTaggingPolicy.concurrencyLimit = 3` using a Swift `withTaskGroup` or semaphore inside the outer task body. This is **not** a `TaskQueue` concurrency limit — it is local to the batch execution function.
- Create `AppModel+TagBatchExecution.swift` (separate from `AppModel+TagExecution.swift`). Each article in the batch is iterated by the outer task;
- On force-quit, resume-from-last-checkpoint on next launch: track processed `entryId` set in a `tag_batch_run` DB record (see §4.6).
- Batch input text: **title + `Entry.summary` only** (no full Readability body). Rationale: cost control; summaries are sufficient for conservative topic labelling.

### 4.6 Batch Run Persistence Schema

Add a `tag_batch_run` table to track batch state across launches:

```sql
CREATE TABLE tag_batch_run (
    id INTEGER PRIMARY KEY,
    status TEXT NOT NULL DEFAULT 'running',  -- running | completed | cancelled
    scopeLabel TEXT NOT NULL,                -- "past_week" | "past_month" etc.
    totalEntries INTEGER NOT NULL,
    processedEntries INTEGER NOT NULL DEFAULT 0,
    newTagNames TEXT,                        -- JSON array of net-new tag names created
    createdAt REAL NOT NULL,
    updatedAt REAL NOT NULL
);
```

The `status = 'running'` guard prevents starting a second batch before sign-off is completed.

### 4.7 Error Handling Surface

- **STRICT PROHIBITION:** No modal `.alert` for LLM route failures, API rate limits, or parse errors in either tagging mode.
- Panel mode: silent fallback to NLTagger; no visible error.
- Batch mode: surface status via the batch run progress UI in Settings. A Reader banner is NOT used for batch failures.
- `FailurePolicy.shouldSurfaceFailureToUser` must return `false` for both `AppTaskKind.tagging` and `AppTaskKind.taggingBatch`.

### 4.8 Required Code-Layer Changes (Pre-Implementation Checklist)

The existing placeholder handling for `.tagging` in `AgentRunCore.swift` pre-dates this design and must be replaced before Phase 4 implementation begins.

**`AppTaskContracts.swift` — `AppTaskKind` enum**: Add two cases:
- `case tagging` (panel)
- `case taggingBatch` (batch background)

**`TaskLifecycleCore.swift` — `UnifiedTaskKind`**:
- Add `case taggingBatch`.
- Update `appTaskKind`: `.tagging → .tagging`, `.taggingBatch → .taggingBatch`.
- Update `from(appTaskKind:)`: add `.tagging → .tagging`, `.taggingBatch → .taggingBatch`.

**`AgentRunCore.swift` — `AgentRunConcurrencyPolicy.init` defaults**: Replace the legacy `.tagging: 2` / `.tagging: 1` placeholder values with:
- `perTaskConcurrencyLimit: [.tagging: 1, .taggingBatch: 1]`
- `perTaskWaitingLimit: [.tagging: 0, .taggingBatch: 0]`

(Replace-on-reopen for panel and no-queue for batch are enforced by `startTaggingRun` call-site logic, not by a waiting slot.)

**`FailurePolicy.swift` — `shouldSurfaceFailureToUser(kind:)`**: Add:
- `case .tagging: return false`
- `case .taggingBatch: return false`

**`TaskTimeoutPolicy.swift` — `executionTimeoutByTaskKind`**: Add:
- `.tagging: 15` (12 s panel LLM + margin; hard cap on panel task lifetime in seconds)
- `.taggingBatch` entry omitted (no execution-level deadline; batch runs until completion or user cancels)

**No new `AgentTaskType` case required**: `AgentTaskType.tagging` (DB-level type used in `AgentTaskRun` records) is shared by both modes. The per-entry LLM requests inside a batch run record themselves as `taskType: .tagging`.

---

## 5. Policy Constants

All constants are defined in `Core/Tags/TaggingPolicy.swift` and `Core/Tags/BatchTaggingPolicy.swift`. No magic numbers elsewhere.

### 5.1 Tagging Panel (`TaggingPolicy`)

| Constant | Confirmed Default | Rationale |
|---|---|---|
| `maxAIRecommendations` | **5** | User has manual selection control; broader suggestion surface increases utility. |
| `maxExistingTagChips` | **10** | UI balance; tune after first visual review. |
| `provisionalPromotionThreshold` | **2** | Batch mode explicitly bypasses this threshold (all batch tags stay provisional until sign-off). This value therefore governs only manual + panel-accepted tags, where two intentional user actions are a sufficient signal for promotion. Setting it to 3 would cause visible confusion (a tag the user applied twice still absent from the sidebar). |
| `maxVocabularyInjection` | **50** | Tune after real-world vocabulary size testing; irrelevant in early usage when the library is small. |
| `maxNewTagProposalsPerEntry` | **3** | Max new tag names (not in existing vocabulary) the panel prompt asks the LLM to propose per article. Injected as `{{maxNewTagCount}}` in the prompt template. Not enforced client-side — sign-off and alias resolver are the quality gates. |
| `panelLLMTimeoutSeconds` | **12** | Initial default; tune after latency testing with target models. May need to increase for remote providers. |

### 5.2 Batch Tagging (`BatchTaggingPolicy`)

| Constant | Confirmed Default | Rationale |
|---|---|---|
| `maxEntriesPerRun` | **100** | At `concurrencyLimit = 3` and ~10 s per article, 100 articles ≈ ~330 s total. 300 would be ~1000 s, too long for a synchronous user-initiated run. |
| `maxTagsPerEntry` | **3** | Max total tags (matched + new) the batch prompt asks the LLM to assign per article. |
| `maxNewTagProposalsPerEntry` | **2** | Max new tag names the batch prompt asks the LLM to propose per article. More conservative than panel (3) because sign-off burden scales with corpus size. Injected as `{{maxNewTagCount}}`; not enforced client-side. |
| `maxVocabularyInjection` | **50** | Shared with `TaggingPolicy`. |
| `concurrencyLimit` | **3** | Max parallel LLM requests during a batch run. |

### 5.3 Recommendation (`RecommendationPolicy`)

| Constant | Confirmed Default | Rationale |
|---|---|---|
| `relatedEntriesCount` | **5** | Max entries in the Reader "Related Content" strip. |
| `minimumSharedTagCount` | **2** | Applied only when strip has ≥ 3 qualifying entries; prefer fewer high-signal results over many weak ones (Phase 6). |

---

## 6. Prompt Contracts

### 6.1 Response Format: Flat JSON Array (Both Modes)

The LLM is asked to return a **flat JSON array of strings only**. All matching/deduplication logic runs on the client side after the LLM responds.

```json
["swift", "developer tools", "wwdc"]
```

Rationale for flat array over `{"matched": [...], "new": [...]}`:
- Asking the LLM to self-classify against the injected vocabulary adds cognitive load and introduces a separate failure mode (LLM mis-classifying a fuzzy match).
- The matched/new split is a deterministic DB lookup — trivially cheap on the client side and 100% correct.
- A flat array is reliably produced by all model tiers (including small local models) and requires minimal prompt complexity.

**Client-side post-processing pipeline** (same for both modes):
1. JSON parse `[String]` from LLM response.
2. For each name: apply `TagNormalization.normalize(_:)`.
3. Strict DB match on `tag.normalizedName` → if found, it is a **matched** tag (safe to write immediately).
4. Alias lookup on `tag_alias.normalizedAlias` → if found, resolve to canonical tag ID (also **matched**).
5. If no match: it is a **new** tag proposal.
   - Panel mode: treat as a new tag name; if user taps it, `assignTags(source: "manual")` creates the tag normally.
   - Batch mode: collect into `newTagNames` list for sign-off; do **not** write to DB until user approves.

### 6.2 `tagging.default.yaml` Contract (Single-Article Panel)

Key template variables:

| Variable | Source | Notes |
|---|---|---|
| `{{existingTagsJson}}` | Top `TaggingPolicy.maxVocabularyInjection` non-provisional tags by `usageCount DESC`, serialized as JSON array | Empty array `[]` if no tags exist yet |
| `{{maxTagCount}}` | `TaggingPolicy.maxAIRecommendations` | Injected as integer string |
| `{{title}}` | `Entry.title` | |
| `{{body}}` | First 800 chars of Readability-extracted body, or `Entry.summary` if unavailable | Truncated to limit token cost |

System prompt responsibilities (non-negotiable):
- Output MUST be a raw JSON array and nothing else — no markdown fences, no explanations, no preamble.
- Return at most `{{maxTagCount}}` tags total. Fewer is acceptable; zero is acceptable if truly none fit.
- Prefer terms from `{{existingTagsJson}}` when they accurately describe the content. Exact string match expected (case-insensitive).
- When proposing new terms not in the list, use only English letters and spaces, max 3 words per term. Propose at most `{{maxNewTagCount}}` new terms.
- Do not combine, abbreviate, or paraphrase existing terms.

### 6.3 `tagging.batch.default.yaml` Contract (Batch Mode)

Differences from the single-article template:

| Dimension | Single-article | Batch |
|---|---|---|
| Input body | Title + first 800 chars of full body | Title + `Entry.summary` only |
| `{{maxTagCount}}` | `TaggingPolicy.maxAIRecommendations` (5) | `BatchTaggingPolicy.maxTagsPerEntry` (3) |
| `{{maxNewTagCount}}` | `TaggingPolicy.maxNewTagProposalsPerEntry` (3) | `BatchTaggingPolicy.maxNewTagProposalsPerEntry` (2) |
| Precision instruction | Standard | Stronger: "If you are not highly confident, return fewer tags or an empty array." |

Both modes allow new tag proposals. These limits are **prompt-level guidance only** — the LLM is asked to respect them, but they are not enforced client-side. The sign-off sheet is the quality gate for new proposals in batch mode; in panel mode the user manually accepts each chip. Early-stage batch runs are an important mechanism for building up a quality vocabulary, so over-restricting new proposals would be counterproductive.

**Client-side handling of new tags in batch:**
- After normalization + alias resolver, names that do not match any existing tag are classified as "new proposals".
- New proposals from a single batch run are aggregated into `tag_batch_run.newTagNames` (JSON array).
- Sign-off sheet presents each proposed name with its article count. User marks each as **Keep** or **Discard**.
- **Keep**: tag is created as `isProvisional = true`; all pending `entry_tag` rows for this run that reference the name are written.
- **Discard**: the proposed name and all associated `entry_tag` rows from this run are dropped. No DB trace remains.
- Sign-off must be completed before the next batch run can start (enforced by `tag_batch_run.status = 'running'` guard).