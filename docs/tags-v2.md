# Tags System v2 Proposal

> Date: 2026-03-01 (revised 2026-03-02)
> Status: Proposed (revised)
> Evolution from v1: Incorporates "Recommendation-first" focus, progressive AI architecture, and Local-first guarantees.

## 1. Core Principles and Goals

Current information architecture is feed-centric. The proposed tags system adds a cross-feed semantic dimension.

**Fundamental Principles:**
1. **Local-First & AI-Independent:** The tag system must function perfectly without AI assistance. All core logic (extraction, filtering, recommendation) must have a reliable baseline. AI acts as an accelerator, not a dependency.
2. **Recommendation-Driven:** The primary value of tagging is not mere archiving, but discovering user preferences and powering "Related Content" recommendations.

## 2. Progressive Architecture & Target Users

The system uses a "Pipeline of Responsibility" to balance capability, privacy, and token cost across three user tiers:

1. **Baseline / Default (No LLM config):** 
   - Uses native `NLTagger` (macOS built-in) for Named Entity Recognition (organizations, people, places) and capitalized noun extraction on article titles.
   - Experience: Zero config, zero cost, automatic basic matching and co-occurrence recommendations.
2. **Efficiency / Paid API User:**
   - Adopts an **Explicit-Intent** strategy.
   - LLMs are not triggered on feed sync (which would burn tokens on thousands of unread articles), and they do not trigger passively when an entry is opened or starred either.
   - AI tagging strictly triggers when the user explicitly opens the tagging panel for an article. At that moment, LLM-generated tag suggestions are fetched on-demand and shown inside the panel as a recommendation list. The user selects which suggestions to accept before anything is committed to the database.
   - Experience: High-quality semantic tags exactly where it matters, user always in control, minimal API cost.
3. **Power User / Local Model:**
   - Complete control via prompt customization templates (`AgentPromptTemplate`).
   - Supports background "Batch Tagging" task queues to re-index historical entries offline.
   - Experience: Zero-cost, high-privacy, highly customizable knowledge graph generation.

## 3. Key Architectural Decisions

### 3.1 Hierarchy vs. Flat Structure
- **Decision:** Strictly **Flat** tag structure. Avoid hierarchical trees to prevent user/system classification paralysis.
- **Future Extension:** May introduce `Facet` / `Type` (e.g., Topic vs. Entity) to weigh entities higher in recommendation algorithms.

### 3.2 Cold Start Strategy
- **Decision:** No global hardcoded seeds (to avoid localization confusion). 
- **Approach:** 
  - Baseline: Auto-aggregate the most frequent tags provided by the user's subscribed feeds.
  - Generative (Opt-in): Run an AI task over a bounded corpus of the user's recent/starred entries to generate a "personalized vocabulary" mapped to their specific domain interests.

### 3.3 De-duplication and Matching (3-Tier Defense)
To prevent synonym explosion, every tag write — regardless of source — must pass through the following pipeline:

1. **Normalization (Write-Path Gate, always first):** Before any lookup, apply the canonical normalization sequence to the raw input string:
   - Trim leading/trailing whitespace.
   - Lowercase.
   - Replace any run of `-`, `_`, `.`, or whitespace with a single space.
   - Result: `normalizedName`. Examples: `AI-generated` → `ai generated`; `Intel CPUs` → `intel cpus`; `U.S.A.` → `u s a`.
   This normalization is applied at write time for all sources and at read time for all user input (search, filter, panel input).

2. **Strict Match (Database Layer):** Query `tag.normalizedName` with the normalized input. If matched, reuse the existing tag record. No new row is created.

3. **Alias Resolution (Alias System):** If no `normalizedName` match, query `tag_alias.normalizedAlias`. If matched, resolve to the canonical `tagId`. This ensures `llm` and `large language models` collapse to a single canonical record. All sources (NLTagger, LLM, manual) pass through this resolver before any DB write.

4. **Merge (Canonical Consolidation, User-Triggered):** An explicit merge operation in the Tag Management interface: user selects Tag A → merge into Tag B. All `entry_tag` rows pointing to A are updated to B (with `INSERT OR IGNORE` to handle articles already having both); A's `name` is added as an alias of B; A is deleted; B's `usageCount` is recalculated.

5. **Semantic Match (Human-in-the-Loop, Maintenance):** Tags that are orthographically close (e.g. `ChatGPT` vs `Chat-GPT`) but not caught by the alias table are surfaced in a periodic merge-suggestion queue in Tag Management. This is a passive maintenance flow, not a blocking write-path step.

**What is explicitly out of scope for v2:** Hierarchical parent-child relationships between tags. The current flat model does not express "Deep Learning is a subtype of Machine Learning" at the data layer. Semantic grouping is emergent from co-occurrence, not declared topology. This constraint is intentional to avoid classification paralysis.

### 3.4 Tag Relationships
- **Decision:** Implicit relationships defined by **Tag Co-occurrence**. 
- Systems will not maintain rigid maps of "Tag A is related to Tag B". If "AI" and "Chips" frequently appear on the same articles, they naturally form a strong edge in the recommendation graph.

## 4. Product Design & UI Shape

### 4.1 Navigation & Global Context
- Add a segmented tab bar on top of the left sidebar: `Feeds | Tags`.
- Switching to `Tags` acts as a Navigation Root change, displaying a global tag aggregation view.

### 4.2 Filtering and Searching
- Multi-select capped safely at `5` tags to avoid UI crowding and complex query overhead.
- Modes: `Any` (contains at least one) and `All` (contains all, strict boolean).
- Tag modes combine deterministically with existing Unread/Search views.
- Extend the existing `FeedSelection` + `EntryStore.EntryListQuery` flow instead of introducing a new global NavigationState refactor.

### 4.3 Reader UI Integrations

**Tagging Panel (opened via `#` toolbar button):**

The tagging panel is a popover anchored to the toolbar button. It preserves the current working layout and extends it with an AI Suggestions section. Top to bottom:

1. **Text input field** (top): Freeform input with placeholder "Type tags (comma-separated)". `Add` button commits. As the user types, the `From existing tags` section filters by prefix match on `normalizedName` (case-insensitive, separator-normalized).
2. **"AI Suggested" section** (conditional, below input): Up to `TaggingPolicy.maxAIRecommendations` (default: **3**) tag suggestions as chips. Generated on-demand when the panel opens — `NLTagger` provides results immediately (synchronous, off-MainActor); LLM results replace/supplement them asynchronously if a route is configured. Only shown when results are available. Tags already applied to the article or already appearing in the `From existing tags` section are excluded.
3. **"From existing tags" section**: Up to `TaggingPolicy.maxPopularTagSuggestions` (default: **10**) non-provisional tags ranked by `usageCount DESC`. Filters by prefix as the user types. Tags already applied and tags showing in AI Suggested are excluded.
4. **Applied tags list** (bottom): Each tag applied to the current article appears as a row with an `×` dismiss button. This is the existing behavior.

Tapping any chip in sections 2 or 3 immediately calls `assignTags(source: "manual")` and promotes the tag to `isProvisional = false` if it was provisional.

All suggestion chips show canonical names (post alias-resolver). The `From existing tags` section is the "pick from existing" shortcut that reduces typing errors; it naturally grows into a meaningful list as the user's tag vocabulary matures.

**NLTagger quality filters:**
Before NLTagger results are surfaced as suggestions, a post-extraction quality filter drops entities that:
- Contain characters other than letters, digits, spaces, or hyphens.
- Exceed 4 words or 25 characters.
- Are a strict superset of another entity in the same result set (e.g., if both `Intel` and `Intel CPUs` are extracted, `Intel CPUs` is dropped).
These filters are enforced in `LocalTaggingService.extractEntities(from:)` and documented as its behavioral contract. They mitigate (but do not eliminate) NLTagger's tendency to misidentify sentence fragments as entities.

**Related Articles strip (bottom of Reader view):**
- A horizontal scroll strip labeled "Related Content".
- Renders up to 5 entries sharing the most tags with the current article.
- Only appears when the article has at least one non-provisional or manually applied tag.

**Provisional Guard:**
All newly created tags (by any path other than manual user input) start as `isProvisional = true`. They power the Related Articles algorithm but are excluded from the Sidebar tag list until `usageCount >= 2` or the user explicitly applies them via the tagging panel (which promotes them immediately).

## 5. Data & Query Design

### 5.1 Schema (SQLite / GRDB)

- `tag`
  - `id`, `name`, `normalizedName`, `isProvisional` (Boolean), `usageCount`
- `tag_alias`
  - `id`, `tagId`, `alias`, `normalizedAlias`
- `entry_tag`
  - `entryId` (FOREIGN KEY ON DELETE CASCADE), `tagId` (FOREIGN KEY ON DELETE CASCADE), `source` (enum: manual/nltagger/ai), `confidence`

### 5.2 Query Architecture
- Integrate completely into existing `EntryStore.EntryListQuery`.
- `All` mode queries should utilize `INTERSECT` or multi-`INNER JOIN` using the `entry_tag(tagId, entryId)` index to keep pagination behavior stable and performant.

## 6. Rollout Plan

- **Phase 1 (The Baseline Base):**
  - Schema migration, Tag Navigation UI, Reader manual CRUD.
  - Implement Co-occurrence "Related Articles" in Reader.
- **Phase 2 (Explicit-Intent AI, Tagging Panel):**
  - Fully designed tagging panel (see §4.3): Applied Tags, text input, AI Suggestions section, Popular Tags section.
  - `NLTagger` runs on-demand when panel opens; results shown in Suggestions section.
  - LLM suggestions shown on-demand in Suggestions section if configured; nothing written until user accepts.
  - Implement the Alias Resolver (write-path normalization).
  - Add `TaggingPolicy` constants for section size limits.
- **Phase 3 (Power User Tools):**
  - Explicit user-authorized Batch Tagging pipeline (user selects corpus scope + confirms before any write).
  - Tag Management settings page: merge tool, merge-suggestion queue, provisional tag review.
