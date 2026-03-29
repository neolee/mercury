# Digest / Multi-Article Brief Planning Memo

> Date: 2026-03-10
> Status: Proposed
> Scope: Multi-article summary (`digest` / `brief`) planning for the Feed-level reading workflow

This document captures the current product and technical recommendations for a new multi-article summary capability.
It is intentionally scoped as a planning memo so implementation can proceed against a stable contract instead of ad-hoc experiments.

---

## 1. Product Goal

The next-stage feature should not be framed as “merge several article summaries into one long text”.
It should be framed as a reader-facing brief that helps users understand a set of related articles quickly.

The core value is:

- identify the main themes across multiple articles;
- remove duplicated information;
- surface disagreements, uncertainty, and notable differences;
- help users decide which original articles are worth opening in full.

In product language, `digest` is closer to an editorial briefing layer than a larger single-article summary.

---

## 2. Recommended Product Definition

## 2.1 Preferred user-facing concept

Use a concept such as `Digest`, `Brief`, or `Reading Brief` rather than “batch summary”.

Rationale:

- “batch summary” sounds like a mechanical bulk action;
- “digest” better communicates curation, grouping, and synthesis;
- the feature is Feed-scoped, not Reader-detail-scoped.

`brief` is a reasonable internal task name if implementation wants a shorter term, but the UI label should stay reader-friendly and stable.

## 2.2 What the v1 output should contain

The first useful version should generate one concise structured brief with these sections:

1. one-sentence overview of the collection;
2. `3-5` main themes ordered by reader value;
3. representative articles under each theme;
4. disagreements, caveats, or open uncertainty if present;
5. a short “worth reading next” recommendation set.

The output should prioritize scanability over essay-like prose.

## 2.3 What the v1 output should not try to do

Avoid these goals in the initial version:

- full timeline reconstruction across many sources;
- strict factual reconciliation beyond what the selected articles explicitly state;
- generating one monolithic long-form report;
- fully automatic background daily digests before manual digest quality is validated.

---

## 3. Entry Points and Scope

## 3.1 Recommended v1 entry points

Start with explicit user-triggered Feed-level entry points:

- generate digest from the current multi-selection;
- generate digest from a filtered list such as current feed / tag / unread view.

The strongest initial path is multi-selection because it is concrete, user-controlled, and easy to explain.

## 3.2 Suggested future scopes

After the explicit selection flow is stable, add broader scopes:

- `daily`: recent articles within a fixed time window;
- `tag`: recent articles under one tag;
- `feed`: current feed or folder;
- `saved`: starred or saved articles.

These broader scopes should reuse the same underlying digest contract rather than fork a new implementation path.

## 3.3 Suggested v1 limits

Constrain the first version to a bounded input size.

Recommended baseline:

- minimum: `3` articles;
- default practical range: `5-20` articles;
- hard cap: set by token budget and article-length heuristics.

If the selection exceeds the safe cap, the app should ask the user to narrow the set or apply pre-filtering first.

---

## 4. Output Contract

## 4.1 Presentation contract

A digest result should be structured and skimmable, for example:

- one overview sentence;
- bullet list of themes;
- nested bullet list of supporting articles per theme;
- one caveat/disagreement block;
- one next-read block.

Avoid section formats that look too similar to the single-article summary panel.
The user should clearly feel this is a different feature with a different purpose.

## 4.2 Source attribution contract

Every major conclusion should remain traceable to source articles.

Minimum attribution rule:

- each theme should include the titles or identifiers of the supporting articles;
- disagreement bullets should identify which source subset supports each side;
- the UI should provide a way to open the contributing articles for a given theme.

Without attribution, a digest can become much harder to trust than a single-article summary.

## 4.3 Tone and content contract

The digest should remain faithful to the selected articles only.

Hard rules:

- no external facts;
- no invented consensus;
- explicit mention when the article set is incomplete, thin, or internally conflicting;
- prioritize comparative synthesis over article-by-article repetition.

---

## 5. Recommended Implementation Strategy

## 5.1 Preferred architecture: summary-first aggregation

The recommended approach is a two-stage pipeline:

1. `article -> single-article summary`
2. `summary set -> clustered digest`

This is the best fit for the current Mercury architecture because single-article summary execution, prompt loading, runtime projection, and persistence already exist in the `Summary` feature stack.

Relevant current foundations include:

- `Mercury/Mercury/Agent/Summary/AppModel+SummaryExecution.swift`
- `Mercury/Mercury/Agent/Summary/AppModel+SummaryStorage.swift`
- `Mercury/Mercury/Agent/Summary/SummaryContracts.swift`
- `docs/summary-agent.md`

Benefits of the summary-first aggregation path:

- lower token cost than concatenating many full article bodies;
- more stable prompt behavior across large selections;
- better cache reuse;
- clearer provenance because each digest can reference stored per-article summaries;
- easier failure recovery when one article is missing or too long.

## 5.2 Alternative architecture: direct full-text aggregation

A direct pipeline would send all selected article bodies to the model in one request.

This may be acceptable only for very small sets of short articles, but it should not be the primary implementation strategy because it creates predictable problems:

- token pressure grows too quickly;
- long-article variance reduces output stability;
- provenance becomes weaker;
- partial cache reuse is poor.

If direct aggregation exists at all, it should be a narrow fallback or an explicitly small-scope mode.

## 5.3 Recommended v1 pipeline

A practical v1 pipeline can be:

1. resolve selected article set;
2. filter unsupported or empty-content entries;
3. load existing single-article summaries for the requested language/detail level if available;
4. generate missing single-article summaries only where needed;
5. run lightweight clustering / grouping using metadata plus summary text;
6. render one digest prompt from the grouped intermediate representation;
7. persist the digest result and theme/source mapping payload.

This pipeline keeps the expensive LLM synthesis step focused on compressed, higher-signal inputs.

---

## 6. Data and Storage Design

## 6.1 New task concept

Treat digest as a first-class task kind rather than forcing it into the single-entry summary slot model.

A digest is not identified by `entryId`; it is identified by a scope and a source set.

Recommended identity components:

- `scopeType` (`selection`, `feed`, `tag`, `daily`, `saved`);
- `scopeValue` or scope descriptor;
- `targetLanguage`;
- `detailLevel` if the feature reuses summary-style detail controls;
- `articleIDs` or a deterministic content hash for the selected set;
- optional `timeRange`.

## 6.2 Suggested persistence entities

The storage model should likely mirror the existing shared agent-task strategy:

- one shared run record in the existing task-run base;
- one digest payload entity;
- one optional digest-item or digest-cluster entity for traceability.

Suggested digest payload fields:

- `taskRunId`
- `scopeType`
- `scopeValue`
- `articleIDs`
- `articleSetHash`
- `targetLanguage`
- `detailLevel`
- `text`
- `clusterPayload`
- `createdAt`
- `updatedAt`

Suggested optional cluster/item fields:

- `digestRunId`
- `clusterIndex`
- `clusterTitle`
- `articleId`
- `articleTitleSnapshot`
- `rank`

## 6.3 Cache and replacement policy

Digest caching should not be identical to single-article summary caching.

Recommended baseline:

- replace only when the same logical scope key is regenerated;
- keep the latest success per scope key;
- invalidate when the article set changes;
- allow manual regenerate even if cache exists.

A deterministic `articleSetHash` is important so the app can distinguish “same scope label, different actual input set”.

---

## 7. Prompt and Agent Design

## 7.1 New prompt template

Add a dedicated built-in template such as `Resources/Agent/Prompts/digest.default.yaml`.

Do not reuse the single-article summary prompt directly.
The current summary prompt is optimized for one source text and one core argument, which is the wrong abstraction for multi-article synthesis.

## 7.2 Prompt responsibilities

The digest prompt should explicitly instruct the model to:

- detect shared themes across the provided article set;
- merge overlapping points;
- preserve disagreements rather than smoothing them away;
- identify uncertainty or thin evidence;
- rank topics by likely reader value;
- attach supporting source references to each theme.

## 7.3 Input shape

The prompt input should preferably be a compact structured list per article, for example:

- title;
- source/site;
- published date;
- tags if useful;
- existing summary text;
- optional short metadata such as read/starred state.

This is better than injecting raw full article bodies into the digest prompt.

---

## 8. UI Direction

## 8.1 Primary placement

Do not place digest in the Reader detail summary panel.
A digest belongs to collection-level workflow, not single-entry reading workflow.

The recommended initial surface is a Feed-level sheet or panel, for example `DigestSheet`.

## 8.2 Suggested v1 layout

A simple digest sheet can contain:

- header with scope description and article count;
- progress / waiting state area;
- overview sentence;
- theme cards or grouped bullet sections;
- source article list per theme;
- actions such as `Open Articles`, `Copy`, `Regenerate`, and `Close`.

## 8.3 Important interaction rules

Recommended interaction rules:

- clicking a theme reveals or focuses its contributing articles;
- digest failure should stay in the approved host surface for that workflow, not the Reader banner;
- the result should remain useful even when some selected articles were skipped;
- the UI should clearly show how many articles were actually included vs originally requested.

---

## 9. Ranking, Filtering, and Clustering Heuristics

Before the digest LLM step, the app should reduce noise with deterministic pre-processing.

Recommended heuristics:

- de-duplicate by URL or canonical article identity;
- down-rank near-duplicate syndicated versions;
- prioritize articles with stronger user intent signals such as starred, read, or longer dwell time;
- use tags, feed/source, publication date, and embedding-free text similarity as initial grouping hints;
- cap per-source dominance so one outlet does not crowd out all themes.

This pre-processing improves quality and lowers cost even before any advanced ML ranking is introduced.

---

## 10. Main Risks and Mitigations

## 10.1 Repetition and weak synthesis

Risk:

- the output becomes a stitched list of article summaries instead of a digest.

Mitigations:

- cluster before synthesis;
- prompt for merged themes rather than per-article recap;
- enforce source attribution and reader-value ordering.

## 10.2 Hallucinated consensus

Risk:

- the model may present partial overlap as a strong consensus.

Mitigations:

- require disagreement and uncertainty handling in the prompt;
- preserve cluster/source boundaries in the input representation;
- avoid over-compressing contradictory source sets before the digest step.

## 10.3 Cost and token blow-up

Risk:

- article count or article length can grow beyond stable limits.

Mitigations:

- summary-first pipeline;
- hard caps on selection size;
- pre-filtering and truncation policy;
- cache intermediate single-article summaries.

## 10.4 Trust and traceability problems

Risk:

- users cannot tell where a conclusion came from.

Mitigations:

- source attachment per theme;
- “view contributing articles” action;
- optional debug/provenance metadata for future inspection.

---

## 11. Evaluation Metrics

The feature should be judged by workflow value, not just text quality.

Recommended product metrics:

- digest generation success rate;
- median generation latency;
- open-through rate from digest to source article;
- reduction in repeated manual opening of near-duplicate articles;
- save/star/share rate after viewing a digest;
- regenerate rate, which may indicate dissatisfaction with the first result.

Recommended qualitative checks:

- whether themes are genuinely cross-article rather than article-by-article;
- whether disagreements are preserved accurately;
- whether the “worth reading next” picks feel useful.

---

## 12. Recommended Delivery Order

## 12.1 Phase 1

Deliver explicit multi-selection digest generation with:

- manual trigger only;
- bounded article count;
- summary-first aggregation;
- cached successful digest results;
- source-attributed theme output.

## 12.2 Phase 2

Add broader scope presets:

- current feed;
- current tag;
- recent unread;
- daily digest.

## 12.3 Phase 3

Add quality and automation improvements:

- better ranking heuristics;
- improved clustering;
- digest history and regeneration policy;
- optional scheduled generation or notifications.

---

## 13. Current Recommendation Summary

The recommended next implementation is:

- build a Feed-level `digest` feature rather than a Reader-level summary variant;
- reuse the existing single-article summary pipeline as the intermediate representation;
- add a dedicated digest task, prompt, and storage contract;
- keep output structured, source-attributed, and theme-oriented;
- launch with explicit user-triggered multi-selection before any automatic daily briefing workflow.

This path offers the best balance of product clarity, implementation reuse, cost control, and output trustworthiness for the current Mercury codebase.
