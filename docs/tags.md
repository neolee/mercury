# Tags System v1 Proposal

> Date: 2026-02-27
> Last updated: 2026-02-27
> Status: Proposed

## 1. Context and Goal

Current information architecture is feed-centric: users organize and browse entries by source feed.  
The tags system adds a second, cross-feed semantic dimension so users can organize and retrieve entries by topic or concept.

Primary goal:
- Add a stable, low-friction tagging workflow that reuses existing entry list and reader behaviors.

Non-goals for v1:
- No fully automatic, always-on tagging pipeline by default.
- No complex ontology editor or hierarchical tag tree.
- No behavior changes to existing entry actions after an entry is selected.

## 2. Product Shape (v1)

## 2.1 Navigation

- Add a segmented tab bar at the top of the left sidebar: `Feeds` and `Tags`.
- `Feeds` keeps current behavior unchanged.
- `Tags` shows all tags in the system with search and sort.

## 2.2 Tag selection and filtering

- Users can select multiple tags.
- Default selection cap: `5` tags.
- Filter mode switch:
  - `Any`: entry contains at least one selected tag (default).
  - `All`: entry contains all selected tags.
- The right entry list renders results from the current tag query.

## 2.3 Compatibility with existing list behaviors

- Entry list rendering, selection, reader actions, batch actions, and detail view remain unchanged.
- Existing filters (unread/search/feed scope where applicable) should still combine deterministically with tag filters.
- Tag mode is a new query dimension, not a separate reader/runtime subsystem.

## 3. Foundational Tag Policy

## 3.1 Tag count target

- Active system tag count target: `50...200`.
- Per-entry tag count target: `1...5`.

Rationale:
- Too few tags reduce retrieval value.
- Too many tags cause synonym drift, low precision, and UI selection overhead.

## 3.2 Tag semantics and scope

- v1 should focus on topical/semantic tags only.
- Do not mix operational state labels (for example read-state workflow labels) into the same tag pool.
- Keep state/workflow concepts in existing dedicated fields or controls.

## 3.3 Canonicalization

- Every tag should map to one canonical record.
- Support aliases/synonyms (`LLM` -> `Large Language Models`, etc.).
- Merge/rename/delete operations must preserve entry associations.

## 4. Cold Start Strategy

Recommended approach: hybrid bootstrap.

## 4.1 Seed set

- Ship a small curated built-in seed set (`20...40` tags) for immediate usability.
- Seed set should cover broad high-frequency topics only.

## 4.2 AI-assisted discovery (suggestion-first)

- Run AI extraction on a bounded recent corpus (`200...500` entries).
- Produce candidate tags with confidence and example evidence.
- Auto-apply only high-confidence candidates (for example `confidence > 0.85`) if auto-apply is enabled.
- Keep medium-confidence candidates in a review queue for user confirmation.

## 4.3 Human-in-the-loop controls

- Allow quick accept/reject/merge of suggested tags.
- Persist suggestion source metadata (`manual` / `ai` / `import`) and confidence for auditability.

## 5. Data and Query Design

## 5.1 Minimum schema (GRDB/SQLite)

- `tags`
  - `id`, `name`, `normalizedName`, `createdAt`, `updatedAt`, `isSystem`, `isArchived`
- `tag_aliases`
  - `id`, `tagId`, `alias`, `normalizedAlias`
- `entry_tags`
  - `entryId`, `tagId`, `source`, `confidence`, `modelVersion`, `createdAt`

## 5.2 Indexing

- Unique index on `tags.normalizedName`.
- Unique index on `tag_aliases.normalizedAlias`.
- Composite index on `entry_tags(tagId, entryId)`.
- Composite index on `entry_tags(entryId, tagId)`.

## 5.3 Query semantics

- `Any` mode: entries where `EXISTS entry_tags.tagId IN selectedTagIds`.
- `All` mode: entries grouped by `entryId` with `HAVING COUNT(DISTINCT tagId) == selectedTagCount`.
- Combine tag predicate with existing unread/search/feed predicates through one query builder path to avoid behavioral drift.

## 6. Runtime and Execution Considerations

- AI tag generation must run through existing long-running orchestration (`TaskQueue` / `TaskCenter`) instead of ad-hoc UI tasks.
- No implicit cancellation of in-flight tasks without explicit user intent.
- Checkpoint and recovery rules should match current agent-task resilience expectations.

## 7. Key Risks and Mitigations

- Synonym explosion:
  - Mitigate with canonical tags + alias mapping + merge tooling.
- Low-quality generic tags:
  - Mitigate with stopword/banlist and minimum information threshold.
- Performance regression in list path:
  - Keep `EntryListItem` lightweight and ensure tag joins are index-backed.
- User trust risk from opaque AI labeling:
  - Show concise evidence/explanation for suggested tags and allow one-click correction.

## 8. Rollout Plan

## 8.1 v1

- Manual tag CRUD.
- `Feeds | Tags` sidebar switch.
- Multi-select tags with `Any/All`.
- Entry list integration with existing query filters.

## 8.2 v1.5

- AI suggestion queue (no default auto-apply).
- Suggestion review actions (`accept`, `reject`, `merge`).

## 8.3 v2

- Optional auto-tagging with explicit opt-in.
- Quality dashboard (coverage, precision proxies, merge pressure).

## 9. Success Metrics

- Tag adoption: percentage of active users with at least one tag interaction per week.
- Retrieval utility: share of entry opens originating from tag-based queries.
- Quality signal: suggestion acceptance rate and post-accept edit/merge rate.
- Performance: entry list query latency under tag filters remains within existing interactive targets.

## 10. Open Questions

- Final max selected tag count (`3`, `5`, or adaptive by mode)?
- Should seed tags be globally fixed or locale/profile-aware?
- Should `All` mode support weighted relevance ordering, or strict boolean filtering only in v1?
