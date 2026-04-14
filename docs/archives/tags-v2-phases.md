# Tags System v2 Development Phases (Checklist)

> Date: 2026-03-01 (revised 2026-03-03)
> Status: Release-ready — Phases 1–5 complete; Phase 6 remains optional follow-up tuning
> Purpose: Staged execution plan & testable checklist for V2 Tags System

This document breaks down the `tags-v2.md` and `tags-v2-tech-contracts.md` into actionable, testable phases. Each stage is designed to be incrementally deployable, risk-controlled, and testable without waiting for the entire system to be finished.

---

## Phase 1: Data Layer & Core Mechanics (The Foundation)
**Goal:** Establish the database schema, models, and core pure-local tag operations. No UI changes or AI in this phase.

- [x] **1.1 Database Migration**
  - Add SQLite schema definitions for `tag`, `tag_alias`, and `entry_tag` in `DatabaseManager+Migrations.swift`.
  - Compile-check: App launches cleanly, database migrates successfully without crashing.
- [x] **1.2 Swift GRDB Models**
  - Define `Tag`, `TagAlias`, and `EntryTag` structs in `Models.swift`.
  - Establish `hasMany(through:)` and `belongsTo()` relationships.
  - Write `TagsDatabaseTests`: Verify you can insert a Tag, assign it to an Entry, and query `Entry.tags`.
- [x] **1.3 Transaction Core Logic**
  - Implement `EntryStore.assignTags(to:names:source:)` using atomic `db.write`.
  - Implement `isProvisional` logic (auto-flip `isProvisional = false` if `usageCount >= 2`).
  - Write `TagAssignmentTests`: Verify synonym deduplication (`normalizedName`) and count accumulation.
- [x] **1.4 Query Integration (`EntryListQuery`)**
  - Add `tagIds` and `tagMatchMode` directly to `EntryStore.EntryListQuery`.
  - Write `TagQueryTests`: Verify `.any` and `.all` mode SQL builder fetches the correct entries without breaking feed/unread scopes.

---

## Phase 2: Navigation & Manual UI (The Basic UX)
**Goal:** Expose the Tags database to the UI. The user should be able to manually categorize entries and filter the list by tags.

- [x] **2.1 Global Tag Sidebar**
  - Modify the Main Sidebar to support `Feeds | Tags` segmented control.
  - Implement `TagListViewModel` to fetch and display non-provisional (`isProvisional == 0`) tags.
  - **Contextual tag management (right-click / secondary click on any tag row):** Rename, Delete, Merge into… (opens a tag picker for the merge target). These are the day-to-day lightweight operations; full management tools live in Phase 5.2 Settings.
  - Manual UI Test: Toggle between Feeds and Tags visually; right-click a tag and rename it.
  - Status: Fully implemented. Core display and multi-select done. Contextual right-click actions implemented: Rename opens `TagRenameSheet` (a dedicated SwiftUI sheet with its own `@State`, bypassing the macOS NSAlert/NSTextField view-reuse bug) via `EntryStore.renameTag(id:newName:)` + `AppModel.renameTag`; Delete shows a confirmation alert via `EntryStore.deleteTag(id:)` + `AppModel.deleteTag`. Deleting while the tag is selected immediately removes it from `selectedTagIds`. Reader tag display is kept in sync via `AppModel.tagMutationVersion` (`@Published Int`) which is incremented on every successful mutation and observed by `ReaderDetailView`. Merge is intentionally deferred to Phase 5.2.
- [x] **2.2 Tag Filtering UI**
  - Wire up Sidebar tag selection (checkboxes/multi-select) to the existing `FeedSelection`-driven selection/query flow.
  - Add the `Match: Any | All` toggle switch.
  - Manual UI Test: Clicking tags properly updates the central Entry List based on Phase 1's `EntryListQuery`.
  - Status: Implemented. `selectedTagIds: Set<Int64>` + `tagMatchMode` bindings wired through `ContentView` → `EntryListQuery`. Manual UI verification pending.
- [x] **2.3 Tagging Panel in Reader**
  - Add a `#` button to the Reader Toolbar to open the Tagging Panel.
  - The panel is a popover. Sections from top to bottom (preserving current working layout):
    1. **Text input field**: freeform new tag input with placeholder "Type tags (comma-separated)" and an `Add` button. Typing live-filters the `From existing tags` section by prefix match on `normalizedName`.
    1b. **"Did you mean:" row** (conditional): appears immediately below the input field when a word boundary (space or comma) is typed. Shows a single inline suggestion link. Computed by `TagInputSuggestionEngine`; see Phase 3.4 for details.
    2. **"AI Suggested" section** (conditional): up to `TaggingPolicy.maxAIRecommendations` (= 3) chips. Appears only when suggestions are available. Tags already applied to the article or already shown in the section below are excluded. See Phase 3.2 for generation contract.
    3. **"From existing tags" section**: up to `TaggingPolicy.maxExistingTagChips` (= 12) non-provisional tags ranked by `usageCount DESC` (see Phase 2.4). Filters by prefix as user types. Tags already applied and tags showing in AI Suggested are excluded.
    4. **Applied tags list**: each tag on this article appears as a row with an `×` dismiss button. This is the existing behavior.
  - Tapping any chip in sections 2 or 3 immediately calls `assignTags(source: "manual")` and promotes the tag to `isProvisional = false` if it was provisional.
  - All suggestion chips show canonical names (post alias-resolver).
  - Display active tags beneath the article title in the Reader body (read-only, `#`-prefixed, one summary row).
  - Manual UI Test: Open panel, type a new tag, apply a suggested tag, verify both appear in the applied list and under the article title and persist after navigating away and back.
  - Status: Fully implemented. Extracted to `ReaderTaggingPanelView.swift`. All five sections functional. Tags displayed as capsule chips (not `#`-prefixed prose) beneath the article title.

- [x] **2.4 Popular Tags Service**
  - Implement `EntryStore.fetchPopularTags(excluding:limit:)` that returns up to `limit` non-provisional tags ordered by `usageCount DESC`, excluding any `Tag.id` in the `excluding` set.
  - The `excluding` set is the union of: IDs of tags already applied to the current article + IDs of tags shown in the AI Suggested section.
  - This query is called lazily when the tagging panel opens; results are held as `@State` in the panel view and are not continuously observed.
  - Define a `TaggingPolicy` type (enum) in `Core/Tags/TaggingPolicy.swift` with constants: `maxAIRecommendations = 3`, `maxExistingTagChips = 12`, `provisionalPromotionThreshold = 2`.
  - **`normalizedName` generation rule (implemented):** `TagNormalization.normalize(_:)` in `Core/Tags/TagNormalization.swift` — trim → lowercase → replace any run of `-`, `_`, `.`, or whitespace with a single space. Marked `nonisolated` to be callable from any isolation context. `EntryStore.normalizedTagPairs` has been updated to use it.
  - Manual UI Test: After assigning tags to several articles, open the tagging panel on a new article and confirm the "From existing tags" section lists tags sorted by frequency of use, the correct names display, and the separator normalization collapses variants correctly.
  - Status: Implemented. `fetchPopularTags` is not a separate function; `EntryStore.fetchTags(includeProvisional: false)` orders by `usageCount DESC` and achieves the same result. Exclusion of already-applied and AI-suggested tags is done client-side in `ReaderTaggingPanelView.existingTagSuggestions`. `TaggingPolicy.swift` created with all three constants.

---

## Phase 3: Zero-Cost NLP & Metadata (The Baseline Automation)
**Goal:** Implement the "Local Only" processing tier to automatically tag articles without requiring any explicit AI API.

- [ ] **3.1 RSS Metadata Extraction** — **Removed**
  - RSS `<category>` tags are not imported automatically. The decision: feed authors apply categories inconsistently; unfiltered `<category>` data caused mass-import of tens of tags per article during development. Auto-import of untrusted metadata without user intent conflicts with the Explicit-Intent principle established for AI tagging.
  - If RSS category surfacing is revisited in the future, the design must require explicit user acceptance (e.g., surfaced as suggestions in the tagging panel, not written directly to `entry_tag`).
  - The `source: "rss"` value is reserved in the schema but no production code path currently writes it.
- [x] **3.2 macOS `NLTagger` On-Demand Service**
  - `actor LocalTaggingService` in `Feed/UseCases/LocalTaggingService.swift`. `extractEntities(title:summary:)` uses a **dual strategy**:
    - **Title**: named entities (`.organizationName`, `.personalName`, `.placeName`) **plus** capitalized nouns via `lexicalClass` scheme (≥ 3 chars, uppercase-initial — surfaces technical terms like "Swift", "GraphQL", "Kubernetes").
    - **Summary**: named entities only. RSS summaries are truncated HTML fragments; noun extraction on this corpus produces too much noise.
  - Named entities appear before nouns in the result list (higher confidence). Both passes are deduplicated before quality filters run.
  - **Trigger contract (implemented):** `LocalTaggingService` is called only when the tagging panel opens. The old `runLocalTagging(for:)` DB-writing call has been removed from `ReaderDetailView.task(id:)` and replaced with `loadNLPSuggestions(for:)` which populates `@State var nlpSuggestions: [String]` in-memory only. Wired via `onChange(of: isTagPanelPresented)` in `ReaderDetailView`. Suggestions are cleared when the panel closes or the entry changes.
  - **Post-extraction quality filters (implemented)** in `LocalTaggingService.applyQualityFilters(to:)` (nonisolated static, testable directly):
    - Character filter: drops entities containing characters other than letters, digits, spaces, or hyphens.
    - Length filter: drops entities exceeding 4 words or 25 characters.
    - Superset dedup: drops entities whose `normalizedName` has another entity's `normalizedName` as a strict word-prefix (e.g., `Intel CPUs` dropped when `Intel` is also present).
  - **"AI Suggested" panel section (implemented):** renders up to `TaggingPolicy.maxAIRecommendations` (= 3) chips between the input field and the "From existing tags" section. Tapping a chip calls `addSuggestedTag(_:)` which writes `source: "manual"` and removes the chip from the suggestions list. "From existing tags" excludes tags already shown in AI Suggested.
  - **Tests:** `LocalTaggingServiceTests` — updated to match new `extractEntities(title:summary:)` dual-strategy signature. All tests compile and pass.
- [x] **3.3 Local Recommendation Engine (Co-occurrence)**
  - `EntryStore.fetchRelatedEntries(for:limit:)` implemented: shared-tag co-occurrence SQL, ranked by `matchScore DESC`, falls back to empty array on no tags or error.
  - `ReaderRelatedEntriesView` horizontal card strip rendered at bottom of reader pane when `relatedEntries.isEmpty == false`.
  - Manual UI Test: Articles sharing similar manual tags correctly appear in the related section.
- [x] **3.4 Tag Input Suggestion Engine**
  - Implemented in `Core/Tags/TagInputSuggestion.swift` as `TagInputSuggestion` (enum) + `TagInputSuggestionEngine` (stateless enum).
  - **Trigger:** when a space or comma is appended to `tagInputText`, the last completed token is extracted and passed to `TagInputSuggestionEngine.suggest(for:in:excluding:)`.
  - **Priority order (all zero-cost, no network):**
    1. Exact match in `searchableTags` (all tags, including provisional) → no suggestion.
    2. Fuzzy match (Levenshtein ≤ 2) against `searchableTags` → suggest adopting the existing tag (`.existingMatch`).
    3. `NSSpellChecker` correction → suggest corrected spelling (`.spelling`).
  - **Spell-check guard rules (applied per word before `NSSpellChecker`):**
    - Skip ALL-CAPS words (`WWDC`, `API`, `LLM`) — treated as abbreviations.
    - Skip CamelCase words (`SwiftUI`, `CoreML`, `iPhone`) — treated as technical identifiers.
    - All other forms — including short lowercase words like `teh` — are checked.
  - **Replacement contract:** when the user taps the "Did you mean: X?" link, only the triggering token is replaced in `tagInputText` (backwards search by original string); the rest of the input is untouched. The user may ignore the suggestion and Add the original token unchanged.
  - **Extensibility:** new suggestion sources (e.g. AI-suggested names in Phase 4) are added as new `TagInputSuggestion` enum cases; the UI renders all cases identically with no changes required.
  - **Tests:** `TagInputSuggestionEngineTests` — complete coverage: empty/whitespace inputs, exact-match suppression, fuzzy match at edit distance 1 and 2, above-threshold suppression, short token guard, excluding set skip, closest-candidate selection, property checks for both suggestion cases, and edit distance utility unit tests.

---

## Phase 4: Agent & LLM Integration (Smart AI Acceleration)
**Goal:** Wire single-article LLM-powered tag suggestions into the tagging panel. Establish agent settings UI as a foundation for batch tagging.

> Implementation order: 4-S1 → 4-S2 → 4-S3 → 4-S4 → 4-S5. Complete Settings UI (4-S2) early so all later work has visible entry points.

- [x] **4-S1 (Foundation): `TaggingAgentDefaults` + Availability**
  - Add `TaggingAgentDefaults` struct in `AppModel+Agent.swift` with `primaryModelId` and `fallbackModelId`. Add `loadTaggingAgentDefaults()` and `saveTaggingAgentDefaults()` backed by UserDefaults keys `Agent.Tagging.PrimaryModelId` and `Agent.Tagging.FallbackModelId`.
  - Fix `checkAgentAvailability(for: .tagging)`: remove the hardcoded `return false`; replace with the same logic as `.summary` — read UserDefaults model IDs, query `supportsTagging == true && isEnabled && !isArchived` models, verify at least one has an enabled provider.
  - Add `@Published var isTaggingAgentAvailable: Bool = false` to `AppModel`. Update `refreshAgentAvailability()` to include the tagging check.
  - Note: `supportsTagging` is always written as `true` when a model is created (same policy as `supportsSummary`/`supportsTranslation`). No per-model toggle is exposed in the UI.
  - **Code-layer pre-conditions** (per §4.8 of tech contracts — must be done before 4-S4):
    - Add `case tagging` and `case taggingBatch` to `AppTaskKind` in `AppTaskContracts.swift`.
    - Add `case taggingBatch` to `UnifiedTaskKind` in `TaskLifecycleCore.swift`; update `appTaskKind`, `from(appTaskKind:)`, `from(agentTaskKind:)` mappings.
    - Update `AgentRunConcurrencyPolicy.init` defaults in `AgentRunCore.swift`: replace the legacy `.tagging` entries with `[.tagging: 1, .taggingBatch: 1]` active limits and `[.tagging: 0, .taggingBatch: 0]` waiting limits.
    - Add `case .tagging: return false` and `case .taggingBatch: return false` to `FailurePolicy.shouldSurfaceFailureToUser`.
    - Add `.tagging: 15` to `TaskTimeoutPolicy.executionTimeoutByTaskKind` (no entry for `.taggingBatch` — batch has no execution-level deadline).

- [x] **4-S2 (Settings UI): Agents > Tagging + General > Tag System**
  - **Agents settings page**: Add a Tagging section below Translation. Contents:
    - Primary Model picker (same component as Summary/Translation).
    - Fallback Model picker.
    - Custom Prompts entry point (opens `AgentPromptTemplateStore` editor for `tagging.default.yaml`).
    - No `targetLanguage` or `detailLevel` fields (not applicable to tagging).
  - **General settings page**: Add a "Tag System" section. Contents:
    - **"Enable Tagging Agent" toggle**: disabled + explanatory caption if no tagging agent is configured; otherwise toggles `UserDefaults["Agent.Tagging.Enabled"]`. When off, the panel falls back to NLTagger only and batch tagging is unavailable.
    - **"Batch Tagging..." button**: disabled when the toggle is off; opens the batch tagging sheet (Phase 5.1).
    - **"Tag Library..." button**: always enabled; opens the Tag Management settings page (Phase 5.2).
  - At this stage the Batch Tagging and Tag Library destinations can be placeholder stubs — the Settings navigation structure must be fully routed to enable progressive implementation.

- [x] **4-S3 (Prompt): `tagging.default.yaml`**
  - Create `Resources/Agent/Prompts/tagging.default.yaml`.
  - Template variables: `{{existingTagsJson}}`, `{{maxTagCount}}`, `{{maxNewTagCount}}`, `{{title}}`, `{{body}}`.
  - `{{existingTagsJson}}`: top `TaggingPolicy.maxVocabularyInjection` non-provisional tags by `usageCount DESC`, serialized as a JSON array. Empty array if no tags exist.
  - `{{maxTagCount}}`: `TaggingPolicy.maxAIRecommendations` (= 5).
  - `{{maxNewTagCount}}`: `TaggingPolicy.maxNewTagProposalsPerEntry` (= 3). Prompt-level guidance; not enforced client-side.
  - `{{body}}`: first 800 chars of Readability-extracted body; fall back to `Entry.summary` if unavailable.
  - System prompt must enforce: output is a raw JSON array of strings only (no markdown, no preamble), at most `{{maxTagCount}}` items total, prefer terms from `{{existingTagsJson}}` (exact match expected), new terms must be English-only max 3 words with at most `{{maxNewTagCount}}` new terms, return `[]` if nothing fits confidently.
  - No manual registration step is required. `AgentPromptTemplateStore` auto-discovers all `.yaml`/`.yml` files placed in `Resources/Agent/Prompts/`. Placing the file with the correct `taskType: tagging` YAML field is sufficient.

- [x] **4-S4 (Execution): `AppModel+TagExecution.swift`**
  - Create `AppModel+TagExecution.swift`. This file covers **panel mode only**. Batch execution lives in `AppModel+TagBatchExecution.swift` (Phase 5.1).
  - Implement `func startTaggingRun(for entry: Entry)` using `AgentTaskKind.tagging` / `AppTaskKind.tagging`.
  - **Panel mode scheduling policy**: `AgentRunOwner(taskKind: .tagging, entryId: entry.id, slotKey: "panel")`. Apply replace-on-reopen: if an active task for this owner exists, cancel it before enqueueing the new one. No waiting slot. This is a call-site policy, not an `AgentRunStateMachine` constraint.
  - **Execution internals** (non-streaming):
    1. `resolveAgentRouteCandidates(taskType: .tagging, primaryModelId:, fallbackModelId:)` from `loadTaggingAgentDefaults()`.
    2. `db.read`: fetch top `TaggingPolicy.maxVocabularyInjection` non-provisional tags by `usageCount DESC` for `{{existingTagsJson}}`.
    3. Build `LLMRequest` with `stream: false`; resolve template `tagging.default.yaml` via `AgentPromptTemplateStore`.
    4. `AgentLLMProvider.complete(request:)` — execution timeout is enforced by `TaskTimeoutPolicy.executionTimeoutByTaskKind[.tagging]` (15 s).
    5. Parse flat `[String]` JSON. On failure: log debug issue, complete task as `.failed`.
    6. For each name: normalize → alias resolver → DB strict match. Classify as **matched** or **new proposal**.
    7. Persist `AgentTaskRun` record (with `taskType: .tagging`) + usage telemetry (same as Summary).
    8. Return result via task completion callback to the panel UI (update suggestion state).
  - `FailurePolicy.shouldSurfaceFailureToUser(kind: .tagging)` returns `false`. Failures fall back to NLTagger silently.
  - Also implement `func cancelTaggingRun(for entry: Entry, slotKey: String)` for panel teardown on disappear.

- [x] **4-S5 (Panel Wiring): AI Path in `ReaderTaggingPanelView`**
  - Remove `@State private var aiTask: Task<Void, Never>?`. The panel now observes `AgentRuntimeStore` for the tagging task state of the current entry (same pattern as `ReaderSummaryView`).
  - On `.onAppear` (after NLTagger call):
    - If `appModel.isTaggingAgentAvailable && isTaggingAgentEnabled`: call `appModel.startTaggingRun(for: entry, mode: .panel)`.
    - Show loading indicator while observed state is `.requesting` or `.generating`.
  - On task `.completed`: read resolved tag names from the run result and replace `nlpSuggestions`.
  - On task `.failed` / `.cancelled`: retain NLTagger results, no error shown.
  - On `.onDisappear` or `entry` identity change: call `appModel.cancelTaggingRun(for: entry, slotKey: "panel")`.
  - The `nlpSuggestions` section label remains "AI Suggested" regardless of source (NLTagger or LLM); the distinction is invisible to the user.
  - Status: Implemented via panel event callback flow (`startTaggingPanelRun` / `cancelTaggingPanelRun`) with equivalent user-facing behavior and silent fallback contract.

- [x] **4-S6 (Tests): `TagAliasBypassTests` + Panel Smoke Tests**
  - `TagAliasBypassTests`: verify that simulated LLM outputs ("LLM", "Deep Learning", "ChatGPT") collapse into canonical tag IDs after normalization + alias resolver. Verify that unrecognized output names are returned as-is (new tag proposals).
  - Add a unit test for the JSON parse fallback path: malformed LLM response → empty array, no crash.
  - Manual UI test: open tagging panel with LLM configured → loading indicator appears → suggestions replace NLTagger results → close panel before response → no crash, no dangling task.
  - Status: Added `TagAliasBypassTests` for alias-to-canonical collapse and unmatched-name proposal behavior; JSON parse fallback assertions are covered in `TaggingExecutionTests`.

- [x] **4-S7 (Panel UI Refactor): Unified Suggestion Chip Container with Wrapping**
  - Introduce one shared suggestion container for both **"AI Suggested"** and **"From existing tags"** sections in `ReaderTaggingPanelView`.
  - Keep each section's business logic unchanged:
    - **AI Suggested source contract:** show local NLP suggestions first; when tagging-agent results arrive, merge by placing LLM results first and keeping NLP-only remainder.
    - **From existing tags source contract:** keep existing exclusion/filter/ranking logic (exclude applied + AI-shown tags; idle uses non-provisional popular tags, typing uses searchable tags with prefix match).
  - Replace horizontal-only chip rows with wrapped multi-line chip layout (no horizontal overflow dependency).
  - Keep visual style and interactions unchanged (same chip style, same tap-to-assign behavior, same loading indicator semantics).
  - Add a UI smoke test checklist for long chip labels and high chip counts to verify wrapping behavior in both sections.

- [x] **4-S8 (Contract Alignment): Strict Agent Availability Across Summary/Translation/Tagging**
  - Unify availability definition for all three agents under one explicit contract:
    1. If `primaryModelId` is missing, agent is unavailable.
    2. If primary model exists but its provider is disabled/archived (or model disabled/archived), agent is unavailable.
    3. If task-specific required settings are missing, agent is unavailable.
    4. Otherwise, agent is available.
  - Remove all implicit fallback behavior for availability and route execution that auto-selects default/newest/other models without explicit user choice.
  - Keep the existing exception only for provider-deletion migration behavior (model reassignment during provider deletion flow).
  - Update General Settings gating to rely on strict availability:
    - `Enable AI Tagging` toggle disabled when tagging availability is false.
    - Explanatory caption shown when unavailable.
    - `Batch Tagging...` disabled when availability is false or toggle is off.
  - Add regression tests covering disabled-provider primary model, missing-primary-model, and task-specific-required-setting-missing scenarios for all three agent types.

- [x] **4-S9 (Localization Completion): Tagging-Related Strings and Missing Usage Paths**
  - Execute after 4-S7 and 4-S8 are merged.
  - Fill missing `zh-Hans` translations for existing tagging-related keys in `Localizable.xcstrings`.
  - Add missing keys for any tagging UI strings currently hardcoded or not captured by localization resources.
  - Verify the affected screens end-to-end in Chinese: Reader tagging panel (`AI Suggested`, `From existing tags`, input hint/error text), General > Tag System, and Tag management entry points.
  - Keep debug/internal diagnostics out of localization scope per project localization policy.

---

## Phase 5: Power User Tools & Polish (The Batch Queue)
**Goal:** Complete the backend batching functionality and user-facing tag management utilities.

- [x] **5.1 Batch Tagging Queue**
  - Status: Implemented and closed out. The current implementation contract lives in `tags-v2-batch.md`.
  - Entry point is `General > Tag System > Batch Tagging...`, routed to a real sheet with lifecycle-aware dismissal lock.
  - Current scope set: `Past Week / Past Month / Past Three Months / Past Six Months / Past Twelve Months / All Unread / All Entries`.
  - Current configure controls include both skip filters (`already applied by batch`, `already tagged`) and concurrency (`1...5`, default `3`).
  - Prompt execution uses the shared `tagging.default.yaml` template with `bodyKind = summary`, `maxTagCount = 5`, and `maxNewTagCount = 2`.
  - Large target handling is `warning + explicit confirmation`; a separate `absoluteSafetyCap` remains only as an engineering safeguard.
  - Run lifecycle is fully implemented: `Configure -> Running -> ReadyNext -> Review? -> Applying -> Done`, with staging persistence, review decisions, idempotent chunked apply, and active-lifecycle mutation guards.
  - Relaunch/resume is intentionally not part of the delivered Phase 5 contract; earlier proposal-era text implying cross-launch resume should not be treated as current behavior.
- [x] **5.2 Tag Management Settings Page**
  - Status: Implemented and closed out. The current implementation contract lives in `tags-v2-management.md`.
  - `General > Tag System > Tag Library...` opens a dedicated management sheet.
  - Delivered capabilities:
    - searchable/filterable library list,
    - inspector-driven rename / merge / make permanent / delete,
    - alias add/delete,
    - delete-unused flow,
    - conservative potential-duplicates inspection,
    - active-batch lifecycle mutation blocking.
  - Lightweight sidebar tag actions remain intact and continue to serve day-to-day usage; Tag Library owns library-maintenance workflows.
- [x] **5.3 End-to-End User Verification**
  - Status: Release-prep validation completed through targeted regression tests plus manual app verification during implementation.
  - Automated coverage now includes database/query contracts, panel/batch execution parsing, batch staging/apply behavior, event propagation, lifecycle guards, and Tag Library mutation semantics.
  - Manual release smoke verification is still recommended on a real corpus, but it is no longer a blocker for considering the tag system feature-complete.

---

## Phase 6: Related Entry Recommendation Improvement
**Goal:** Improve the quality and relevance of the "Related Content" strip at the bottom of the Reader pane. The current implementation is a simple shared-tag co-occurrence SQL query; this phase investigates higher-signal ranking approaches.

Status note:
- Deferred for this release.
- The current co-occurrence implementation is stable and shipped; larger ranking changes are intentionally not required to close Tags v2.

- [ ] **6.1 Ranking Signal Audit**
  - Audit the current `fetchRelatedEntries` SQL: document its edge-case behavior (entry with no tags always returns empty; same-feed bias; no recency weighting).
  - Decide which improvements are worth the complexity cost before implementing.

- [ ] **6.2 Recency Decay Weighting**
  - Add a recency penalty to the ranking so very old articles with many shared tags do not crowd out recent ones.
  - Candidate formula: `score = matchScore / (1 + daysSince(publishedAt) / 30)` — tunable via a constant.
  - Validate that strip quality improves on a real feed corpus before committing.

- [ ] **6.3 Same-Feed Bias Reduction**
  - Optionally downweight entries from the same feed as the current article to surface cross-feed discovery.
  - Implement as an opt-in preference rather than a forced behavior.

- [ ] **6.4 Minimum Quality Floor**
  - Filter out entries with `matchScore < 2` (only one shared tag) if the strip would still have at least 3 results; prefer quality over quantity.
  - Configurable via `RecommendationPolicy.minimumSharedTagCount`.

- [ ] **6.5 LLM Semantic Similarity (Post Phase 4)**
  - After the tagging LLM is integrated (Phase 4), explore using tag embeddings or LLM-generated summaries for semantic relatedness ranking as an optional second pass.
  - This is a post-Phase-4 investigation only; not a pre-condition for any earlier phase.
