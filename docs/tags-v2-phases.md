# Tags System v2 Development Phases (Checklist)

> Date: 2026-03-01 (revised 2026-03-03)
> Status: Active — Phases 1–3 complete, entering Phase 4
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
**Goal:** Wire the tags system into the existing Mercury Agent runtime for "Lazy-load" semantic tagging using language models.

- [ ] **4.1 Agent runtime hooks**
  - Reuse existing `AgentTaskKind.tagging` and wire the execution path end-to-end.
  - Add tagging prompt `tagging.default.yaml` inside `Resources/Agent/Prompts/`.
  - Create `AppModel+TagExecution.swift` and map the execution block similar to Summary.
- [ ] **4.2 Tagging Panel AI Integration**
  - When the tagging panel opens for an article and an LLM route is available, submit an async tagging request via `AgentTaskKind.tagging`.
  - While the LLM response is pending, the "Suggested" section shows a loading indicator.
  - On completion, the LLM-generated tag names are passed through the alias resolver and deduplicated against applied tags and popular tags, then displayed as suggestion chips (up to `TaggingPolicy.maxAIRecommendations` = 3).
  - Nothing is written to `entry_tag` until the user taps a chip to accept it.
  - If no LLM route is available, the Suggested section falls back to `LocalTaggingService` (NLTagger) results only, with no loading state.
  - If the LLM call fails or times out, the section silently falls back to NLTagger results (no error alert; failure may be logged as a debug issue per `FailurePolicy`).
  - Remove any logic that triggers AI tagging based on dwell time, entry selection, or starring.
- [ ] **4.3 LLM Execution & Alias Normalization**
  - Inject the *existing* non-provisional Tag JSON list into the prompt template dynamically.
  - Pass the AI result gracefully through the `tag_alias` check before DB insertion.
  - Write `TagAliasBypassTests`: Verify simulated AI outputs ("LLM", "Deep Learning") collapse into Canonical IDs gracefully.
- [ ] **4.4 Route/Timeout Finalization**
  - Finalize dedicated tagging route/timeout behavior (no remaining implicit reliance on generic `custom` semantics).
  - Validate timeout handling, failure projection, and usage telemetry consistency for tagging.

---

## Phase 5: Power User Tools & Polish (The Batch Queue)
**Goal:** Complete the backend batching functionality and user-facing tag management utilities.

- [ ] **5.1 Batch Tagging Queue**
  - Create UI in Tag Management settings (not in the main Reader) for explicitly scoped auto-tagging.
  - User selects a corpus scope from a fixed set: All Unread / Past Week / Past Month / Past Six Months / All Entries.
  - User reviews a scope summary (entry count estimate) and explicitly taps a confirmation button to authorize the run. This double-intent requirement (select scope + confirm) is non-negotiable.
  - **Batch Quality Contract** (strictly enforced, no exceptions):
    - Maximum tags assigned per article: `BatchTaggingPolicy.maxTagsPerEntry` = 3.
    - Minimum confidence for assignment: `BatchTaggingPolicy.confidenceFloor` = 0.8.
    - All outputs pass through the alias resolver before any DB write.
    - All batch-assigned tags start as `isProvisional = true` regardless of current `usageCount`; they do not auto-promote during a batch run.
    - Batch prompt template (`tagging.batch.default.yaml`) is separate from the single-article prompt and must emphasize precision over recall, conservatism over coverage.
  - **New-tag sign-off (required after every batch run):** When the run completes, if any net-new tags were created (tags whose `normalizedName` did not exist before the run), a sign-off sheet is presented:
    - Lists each newly created tag name and how many articles it was assigned to (tag-level summary only; no article-level breakdown required).
    - User can mark each new tag as **Keep** (remains `isProvisional`, follows normal promotion rules) or **Discard** (delete the tag and all its `entry_tag` rows from this run).
    - Existing tags that were merely re-applied to new articles do not appear here and require no review.
    - User must complete sign-off before the next batch run can be started.
  - Orchestration follows `AgentRuntimeEngine` `perTaskConcurrencyLimit[.tagging]`; no unstructured task groups.
  - Validation: Queue checkpoints correctly; force-quitting resumes processing un-tagged entries on next launch.
- [ ] **5.2 Tag Management Settings Page**
  - Create a dedicated Settings sub-page for system-level tag maintenance (supplements the lightweight per-tag right-click actions in the sidebar, which are in Phase 2.1).
  - **Provisional tag review**: Lists all `isProvisional = true` tags with article counts. User can promote (confirm, sets `isProvisional = false`) or delete each.
  - **Merge tool (Canonical Consolidation)**: User selects Tag A → merge into Tag B. The operation:
    1. Re-points all `entry_tag` rows from A's `tagId` to B's `tagId` (with `INSERT OR IGNORE` to handle articles that already have both).
    2. Adds A's `name` as a new `tag_alias` of B.
    3. Deletes Tag A.
    4. Recalculates `usageCount` for Tag B.
  - **Merge suggestion queue**: Surface pairs of tags with high orthographic similarity (Levenshtein distance ≤ 2 on `normalizedName`). Presented as "Did you mean the same thing?" cards for the user to confirm-merge or dismiss.
  - Note: Hierarchical parent-child tag relationships are explicitly out of scope for v2. Semantic grouping of related but non-equivalent tags is approximated by co-occurrence in the recommendation engine, not modeled at the data layer.
- [ ] **5.3 End-to-End User Verification**
  - Complete stress test: Feed parsing → User opens article → Opens tagging panel → Accepts AI suggestion → Tag appears in Sidebar → Tag filter works → Related Articles strip shows correctly → Batch tagging run processes a bounded corpus cleanly.

---

## Phase 6: Related Entry Recommendation Improvement
**Goal:** Improve the quality and relevance of the "Related Content" strip at the bottom of the Reader pane. The current implementation is a simple shared-tag co-occurrence SQL query; this phase investigates higher-signal ranking approaches.

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
