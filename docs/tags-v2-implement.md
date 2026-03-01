# Tags System v2 Implementation Plan

> Date: 2026-03-01
> Status: Planning
> Parent Document: `tags-v2.md`

This document details the technical implementation and UI/UX design for the V2 Tags System. It translates the progressive architecture (Local-first + AI-accelerated) and recommendation-driven goals into actionable implementation modules.

---

## 1. Tag System Settings & Configuration (用户设置)

### 1.1 UI Design
- **Location**: A new `Tags` tab in `AgentSettingsView` (or App Settings).
- **Controls**:
  - **Tagging Engine Mode** (Picker): 
    1. *Local Only (Privacy First)*: Uses built-in `NLTagger` + RSS metadata.
    2. *Smart (Lazy AI)*: Uses LLM only on Starred / Deep read articles.
    3. *Aggressive (Batch AI)*: Permits background AI tasks for older articles (enabled only if a local/free AI model route is detected).
  - **Cold Start Action** (Button): "Generate Initial Tags from Read History" (triggers local NLP or AI dependent on engine mode).
  - **Merge & Cleanup Center** (List): A dedicated sub-view listing `Provisional` tags and highly-similar alias suggestions waiting for user approval.

### 1.2 Technical Implementation
- Add `Agent.Tags.EngineMode` setting to `UserDefaults`.
- Establish a `TagMaintenanceService` to run asynchronous sweeps (finding similar strings with low Levenshtein distance) to populate the Merge & Cleanup Center.

---

## 2. Single Entry Tagging & Recommendation (单篇文章标记与推荐)

### 2.1 UI Design
- **Reader Toolbar**: Add a tag icon (<kbd>#</kbd>). Clicking opens a popover to Add/Remove tags.
- **Tag Display**: Display active tags horizontally below the article title. Click a tag to navigate to the global Tag view.
- **Smart Suggestions**: Within the tagging popover, show "Suggested Tags" distinctly.

### 2.2 Technical Implementation (Pipeline of Responsibility)
When an entry is loaded in the Reader:
1. **Source Metadata Pass**: Extract `<category>` / `<tag>` from the raw FeedKit XML. Map to `tags` matching `normalizedName`.
2. **Local NLP Pass**: Invoke macOS `NLTagger` (Entity type: `.organization`, `.personalName`, `.place`). 
3. **Execution Decision**:
   - If `EngineMode == .LocalOnly` -> Halt and persist these tags (if `confidence` matches).
   - If `EngineMode == .Smart` and the user Stars the entry or reads for > 15 seconds -> Dispatch `AgentTask.tagging(entryId)`.
4. **LLM execution**:
   - Query the LLM using the `AgentPromptTemplate` (`prompt_tag_extraction.yaml`).
   - *Critical Constraint*: The prompt MUST be injected with the JSON array of current non-provisional user tags to force reuse over invention.
5. **Persistence**: Pass resulting tags through the `tag_aliases` normalizer. Save missing ones as `isProvisional = true`.

---

## 3. Related Content Engine (结合当前文章给出相关推荐)

### 3.1 UI Design
- **Location**: At the bottom of the Reader content (appended after the article body).
- **Header**: "Related Content" or "You might also like".
- **Items**: 3 to 5 lightweight `EntryListItem` views. Hovering shows *why* it's recommended (e.g., *Matches tags: Model, Apple*).

### 3.2 Technical Implementation
- **Algorithm (Co-occurrence Match)**:
  - Query: Find top `N` entries that share the maximum number of tags with the currently opened `entryId`.
  - SQL:
    ```sql
    SELECT e.*, COUNT(t.tagId) as matchScore 
    FROM entries e
    JOIN entry_tags t ON e.id = t.entryId
    WHERE t.tagId IN (SELECT tagId FROM entry_tags WHERE entryId = ?)
      AND e.id != ?
    GROUP BY e.id
    ORDER BY matchScore DESC, e.publishedAt DESC
    LIMIT 5;
    ```
- **Caching**: Results should be fetched dynamically upon Entry load, as the SQL query on indexed tables will be sub-10ms.

---

## 4. Tag-based Filtering & List View (按标记筛选生成 List)

### 4.1 UI Design
- **Sidebar**: Segmented control (`Feeds` | `Tags`) at the top of the left sidebar.
- **Tags Tab**: 
  - Lists tags ordered by `usageCount`.
  - Search bar to live-filter the tag list.
  - Checkboxes next to tags to allow Multi-select (up to 5).
- **Match Mode Toggle**: A small toggle above the entry list (`Match: Any | All`).

### 4.2 Technical Implementation
- **Root State**: Extend `NavigationState` to include `tagSelection(Set<Int>, mode: TagMatchMode)`.
- **Query Gateway**: Hook into `EntryStore.EntryListQuery`.
  - Add parameters `tagIds: [Int]` and `tagMatchMode: .any | .all`.
  - **`.any` mode SQL generation**: `AND entries.id IN (SELECT entryId FROM entry_tags WHERE tagId IN (...))`
  - **`.all` mode SQL generation** (using INTERSECT for stability):
    ```sql
    AND entries.id IN (SELECT entryId FROM entry_tags WHERE tagId = A)
    AND entries.id IN (SELECT entryId FROM entry_tags WHERE tagId = B) ...
    ```
- **Provisional Exclusion**: The sidebar tag list query MUST include `WHERE isProvisional = 0` to keep the UI clean.

---

## 5. Batch Tagging Operation (多篇文章自动批量标记后台任务)

### 5.1 UX Scenario
- Intended for Power Users equipped with local AI (Ollama/Qwen3) or those willing to spend tokens.
- **Trigger**: User clicks "Re-index Library" in settings, or selects multiple items in the list to right-click -> "Auto-Tag".

### 5.2 Technical Implementation
- **Queue System**: Hook into the existing `TaskQueue` / `TaskCenter`.
- **Agent Lifecycle**: 
  - Create `AgentTask.batchTagging(entryIds: [Int])`.
  - The task iterates over entries, strictly respecting rate limits/concurrency settings (`Agent.Translation.concurrencyDegree` is analogous).
- **Resilience**: Use `AgentRuntimeStore` to checkpoint state. If the user quits Mercury, the task pauses and resumes upon restart without implicitly canceling.

---

## 6. Daily Serendipity: "The Daily AI Digest" (针对用户的“每日一篇 / 每日话题”推荐)

### 6.1 UI Design
- **Location**: A special banner or pinned section at the top of the "Unread" or "Today" smart feed.
- **Format**: "Today's Focus: {Tag Name}". Shows 1-2 highly relevant unread articles matching a tag the user has historically engaged with, but hasn't read from yet today.

### 6.2 Technical Implementation
- **User Preference Profiling (Local)**:
  - Query: Aggregate tag frequency from the user's previously *Read* or *Starred* entries.
  - Sort by a time-decayed weight (tags engaged with recently count more).
- **Digest Generation**:
  - Daily at startup, select 1 Top Tag from the profile.
  - Fetch 2 unread articles associated with this tag.
  - If using `EngineMode == .Smart`, optionally use LLM to summarize *why* these two articles are interesting together before displaying the banner.

---

## 7. Migration and Schema Enforcement

### 7.1 SQLite Migrations
The `DatabaseManager` will require a v2 migration applying:
```sql
CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT, normalizedName TEXT UNIQUE, isProvisional INTEGER, usageCount INTEGER DEFAULT 0);
CREATE TABLE tag_aliases (id INTEGER PRIMARY KEY, tagId INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE, alias TEXT, normalizedAlias TEXT UNIQUE);
CREATE TABLE entry_tags (entryId INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE, tagId INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE, source TEXT, confidence REAL, PRIMARY KEY (entryId, tagId));
CREATE INDEX idx_entry_tags_tagId ON entry_tags(tagId);
```

### 7.2 Safety Invariants
- `isProvisional` state promotion: Whenever an `entry_tags` INSERT occurs, update `usageCount`. If `usageCount >= 2`, automatically `UPDATE tags SET isProvisional = 0 WHERE id = ?`.
- Tag Deletion: Handled by SQLite `ON DELETE CASCADE`. Removing a tag drops references; removing an entry cleans up its tag mapping without leaving orphans.
