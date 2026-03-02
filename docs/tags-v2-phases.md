# Tags System v2 Development Phases (Checklist)

> Date: 2026-03-01
> Status: Planning
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

- [ ] **2.1 Global Tag Sidebar**
  - Modify the Main Sidebar to support `Feeds | Tags` segmented control.
  - Implement `TagListViewModel` to fetch and display non-provisional (`isProvisional == 0`) tags.
  - Manual UI Test: Toggle between Feeds and Tags visually.
  - Status: Implemented in code; manual UI verification pending.
- [ ] **2.2 Tag Filtering UI**
  - Wire up Sidebar tag selection (checkboxes/multi-select) to the existing `FeedSelection`-driven selection/query flow.
  - Add the `Match: Any | All` toggle switch.
  - Manual UI Test: Clicking tags properly updates the central Entry List based on Phase 1's `EntryListQuery`.
  - Status: Implemented in code; manual UI verification pending.
- [ ] **2.3 Manual Tagging in Reader**
  - Add a `<kbd>#</kbd>` button to the Reader Toolbar.
  - Build a simple popover/sheet to type and attach new tags or remove existing ones.
  - Support displaying active tags just under the article title.
  - Manual UI Test: Apply a manual tag to an article; verify it appears in the DB and filters correctly in the Sidebar.
  - Status: Implemented in code; manual UI verification pending.

---

## Phase 3: Zero-Cost NLP & Metadata (The Baseline Automation)
**Goal:** Implement the "Local Only" processing tier to automatically tag articles without requiring any explicit AI API.

- [ ] **3.1 RSS Metadata Extraction**
  - Intercept raw FeedKit `<category>` entries during sync.
  - Map them automatically via `EntryStore.assignTags(..., source: "rss")`.
  - Validation: Feed sync populates raw tags automatically.
- [ ] **3.2 macOS `NLTagger` Service**
  - Create `actor LocalTaggingService`.
  - Implement `extractEntities(from text: String)` using `NLTagger` (.organization, .personalName, .place).
  - Write `NLTaggerTests`: Pass in a string with "Apple" and "Tim Cook", assert extraction success.
- [ ] **3.3 Local Recommendation Engine (Co-occurrence)**
  - Write the SQL hook `EntryStore.fetchRelatedEntries(for entryId: Int64, limit: Int)`.
  - Build the "You might also like" UI component at the bottom of the Reader view.
  - Manual UI Test: Articles sharing similar manual/rss tags correctly appear in the related section.

---

## Phase 4: Agent & LLM Integration (Smart AI Acceleration)
**Goal:** Wire the tags system into the existing Mercury Agent runtime for "Lazy-load" semantic tagging using language models.

- [ ] **4.1 Agent runtime hooks**
  - Reuse existing `AgentTaskKind.tagging` and wire the execution path end-to-end.
  - Add tagging prompt `tagging.default.yaml` inside `Resources/Agent/Prompts/`.
  - Create `AppModel+TagExecution.swift` and map the execution block similar to Summary.
- [ ] **4.2 The "Smart" Mode Trigger (Lazy Load)**
  - Implement settings toggle `Agent.Tags.EngineMode` in `AgentSettingsView`.
  - Listen for `.isStarred == true` or continuous foreground dwell on the same entry for 15 seconds (reset on entry switch or app background).
  - Submit `AgentTask.tagging(entryId)` to `TaskCenter` passively upon these triggers.
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
  - Create UI for "Re-index Library" in settings.
  - Orchestrate multiple `.tagging` tasks via the `AgentRuntimeEngine`, enforcing `perTaskConcurrencyLimit`.
  - Validation: The queue checkpoints correctly; force-quitting the app resumes processing un-tagged entries on next launch.
- [ ] **5.2 Merge & Cleanup Center**
  - Create the Sub-view in Settings showing `isProvisional` tags.
  - Build simple `Merge(A -> B)` DB method that updates `entry_tag` correctly and cleans up the orphan tag.
- [ ] **5.3 End-to-End User Verification**
  - Complete stress test: Feed parsing -> Star an item -> Agent kicks in -> Tags populate -> User navigates sidebar -> List filters perfectly.
