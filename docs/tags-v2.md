# Tags System v2 Proposal

> Date: 2026-03-01
> Status: Proposed
> Evolution from v1: Incorporates "Recommendation-first" focus, progressive AI architecture, and Local-first guarantees.

## 1. Core Principles and Goals

Current information architecture is feed-centric. The proposed tags system adds a cross-feed semantic dimension.

**Fundamental Principles:**
1. **Local-First & AI-Independent:** The tag system must function perfectly without AI assistance. All core logic (extraction, filtering, recommendation) must have a reliable baseline. AI acts as an accelerator, not a dependency.
2. **Recommendation-Driven:** The primary value of tagging is not mere archiving, but discovering user preferences and powering "Related Content" recommendations.

## 2. Progressive Architecture & Target Users

The system uses a "Pipeline of Responsibility" to balance capability, privacy, and token cost across three user tiers:

1. **Baseline / Default (No LLM config):** 
   - Uses native `NLTagger` (macOS/iOS built-in) for Named Entity Recognition (finding organizations, people, places).
   - Extracts built-in feed metadata (`<category>` tags from RSS).
   - Experience: Zero config, zero cost, automatic basic matching and co-occurrence recommendations.
2. **Efficiency / Paid API User:**
   - Adopts a **Lazy-Evaluation** strategy.
   - LLMs are not triggered on feed sync (which would burn tokens on thousands of unread articles). Instead, AI tagging strictly triggers when an entry is read deeply or Starred.
   - Experience: High-quality semantic tags exactly where it matters, with minimal API cost.
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
To prevent synonym explosion:
1. **Strict Match (Database Layer):** The `normalizedName` field ensures `ai`, `AI`, and ` AI ` are treated identically in SQLite.
2. **Synonym Match (Alias System):** A `tag_alias` table maps semantic matches (e.g., `LLM` -> `Large Language Models`). AI outputs must pass through this normalizer before assignment.
3. **Semantic Match (Human-in-the-Loop):** "Almost identical" tags (e.g., `ChatGPT` vs `Chat-GPT`) are tracked. A background maintenance tool periodically prompts the user to merge highly-similar tags.

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
- **Manual CRUD:** A clear entry point in the Reader toolbar/header to add/remove tags on the fly.
- **Related Articles:** A new section at the bottom of the Reader (`You might also like...`). Renders based on local tag co-occurrence matching.
- **Provisional Guard:** Newly discovered tags (by AI or NLTagger) with a usage count < 2 remain `isProvisional`. They power recommendations but are blocked from polluting the global Sidebar navigation until they pass the threshold or are manually confirmed.

## 5. Data & Query Design

### 5.1 Schema (SQLite / GRDB)

- `tag`
  - `id`, `name`, `normalizedName`, `isProvisional` (Boolean), `usageCount`
- `tag_alias`
  - `id`, `tagId`, `alias`, `normalizedAlias`
- `entry_tag`
  - `entryId` (FOREIGN KEY ON DELETE CASCADE), `tagId` (FOREIGN KEY ON DELETE CASCADE), `source` (enum: manual/rss/nltagger/ai), `confidence`

### 5.2 Query Architecture
- Integrate completely into existing `EntryStore.EntryListQuery`.
- `All` mode queries should utilize `INTERSECT` or multi-`INNER JOIN` using the `entry_tag(tagId, entryId)` index to keep pagination behavior stable and performant.

## 6. Rollout Plan

- **Phase 1 (The Baseline Base):** 
  - Schema migration, Tag Navigation UI, Reader manual CRUD. 
  - Implement RSS Metadata & macOS `NLTagger` extraction.
  - Implement Co-occurrence "Related Articles" in Reader.
- **Phase 2 (Targeted AI Acceleration):** 
  - Introduce Lazy-load AI tagging (runs on Star or continuous foreground reading on the same entry for > 15s; reset on entry switch or app background).
  - Implement the Alias Normalizer and AI Tag prompt templates.
- **Phase 3 (Power User Tools):**
  - Offline Batch tagging pipeline UI.
  - Background Tag merge/cleanup suggestions.
