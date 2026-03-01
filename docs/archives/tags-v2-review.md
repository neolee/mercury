# Tags System v2 Review (Open Decisions)

> Date: 2026-03-01
> Status: Pending decisions before implementation kickoff
> Scope: Unresolved points that can affect execution order, architecture stability, or rework risk

This document tracks the 8 open decisions identified during the pre-kickoff review of:
- `docs/tags-v2.md`
- `docs/tags-v2-implement.md`
- `docs/tags-v2-tech-contracts.md`
- `docs/tags-v2-phases.md`

## 1) Database table naming convention (singular vs plural)

**Question**
Should tags-related tables use singular (`tag`, `tag_alias`, `entry_tag`) or plural (`tags`, `tag_aliases`, `entry_tags`) naming?

**Why this matters**
- Affects migration DDL, GRDB `databaseTableName`, indexes, and all SQL queries.
- Any mismatch causes runtime query failures and migration confusion.

**Recommended default**
Use **singular** table names to align with existing project database naming style (`feed`, `entry`, etc.).

---

## 2) Navigation integration boundary for Tag view

**Question**
Should Tag navigation be implemented as a new global `NavigationState` root abstraction, or as an extension of the existing `FeedSelection`-driven flow?

**Why this matters**
- Defines the implementation cost for Phase 2.
- Choosing a larger navigation refactor now can delay baseline delivery.

**Recommended default**
Start with **minimal extension of current `FeedSelection` + query pipeline**, avoid broad navigation refactor in initial rollout.

---

## 3) Tagging runtime status: placeholder vs executable pipeline

**Question**
Given `tagging` already exists in task/runtime enums, do we treat it as an active deliverable in early phases or as a placeholder until Phase 4?

**Why this matters**
- Impacts scope boundaries of Phase 1/2/3.
- Reduces ambiguity around “done” criteria for agent/runtime integration.

**Recommended default**
Treat tagging runtime as **placeholder in early phases**; only complete end-to-end execution in Phase 4.

---

## 4) Task routing and timeout policy for tagging

**Question**
Should tagging have a dedicated `AppTaskKind`/timeout policy, or temporarily reuse current `custom` route behavior?

**Why this matters**
- Affects consistency of timeout handling, telemetry, and failure classification.
- Influences debuggability and operational behavior for batch tagging.

**Recommended default**
Keep current route short-term, but define a **clear migration plan to dedicated tagging timeout/route semantics** before Phase 4 completion.

---

## 5) RSS metadata extraction insertion point

**Question**
Where exactly should `<category>/<tag>` extraction be implemented: at parser/sync mapping stage, or post-insert enrichment stage?

**Why this matters**
- Directly affects sync performance and data flow complexity.
- Determines whether tag assignment stays atomic with entry ingestion.

**Recommended default**
Implement extraction at **sync mapping pipeline boundary** and feed output into centralized tag assignment transaction.

---

## 6) “Deep read > 15s” trigger definition

**Question**
What is the exact event contract for “deep read” (foreground only? reset on tab switch? reset on entry switch? suspended when app backgrounded?)

**Why this matters**
- Prevents accidental over-triggering and token waste.
- Avoids conflicts with existing read-state auto-mark behavior.

**Recommended default**
Define deep read as **continuous foreground dwell on the same entry**, reset on entry change or app background.

---

## 7) Provisional/usageCount lifecycle semantics

**Question**
How should `usageCount` and `isProvisional` behave for edge cases:
- repeated assignment to same entry
- untag/retag
- tag merge
- manual confirmation

**Why this matters**
- Core to sidebar quality and recommendation stability.
- Incorrect semantics can cause noisy tag lists or unstable promotion/demotion.

**Recommended default**
Count **unique entry associations** only; manual confirmation can force promotion; merge operations recompute or transfer counts deterministically.

---

## 8) Tagging prompt/template contract and assets

**Question**
What is the concrete template contract for tagging (`tagging.default`), including required placeholders and fallback rules?

**Why this matters**
- Needed for deterministic AI behavior and prompt customization support.
- Must support injection of existing non-provisional tags to reduce synonym drift.

**Recommended default**
Define and ship a built-in `tagging.default.yaml` with strict placeholders (entry text + candidate tag list + output schema) before Phase 4 runtime wiring.

---

## Decision Log (to be filled during review)

- [ ] Decision 1 finalized
- [ ] Decision 2 finalized
- [ ] Decision 3 finalized
- [ ] Decision 4 finalized
- [ ] Decision 5 finalized
- [ ] Decision 6 finalized
- [ ] Decision 7 finalized
- [ ] Decision 8 finalized

## Exit Criteria for Kickoff

Implementation can start immediately after all 8 decisions are finalized, with at least:
- stable schema naming,
- stable query integration boundary,
- stable trigger semantics,
- stable Phase-4 tagging prompt/runtime contract.
