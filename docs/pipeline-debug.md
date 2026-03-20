# Reader Pipeline Debugging

## Background

Mercury's Reader pipeline is layered:

```text
Source HTML -> Readability -> cleaned HTML -> Markdown -> Reader HTML cache
```

The production invalidation mechanism today is `ReaderPipelineVersion`, where a version bump forces a lazy rebuild on next open. That is appropriate for app releases, but it is not ergonomic for active development on the Readability library because:

- repeated local testing should not require repeated version bumps
- developers need targeted rebuild controls for the currently selected entry
- the Debug surface should become a durable home for more than one debugging action

This document defines the debug-oriented pipeline invalidation model and the first Debug menu feature set.

---

## Goals

- Replace the current debug button with a Debug menu in debug builds.
- Keep `Show Debug Issues` as one menu item inside that menu.
- Add targeted pipeline re-run actions for the currently selected entry.
- Make pipeline invalidation version-driven wherever possible.
- Keep rebuild logic simple and predictable by deriving downstream validity from upstream validity.
- Prevent AI features from operating on content while the current entry's pipeline is rebuilding.

---

## Existing Problem

The current rebuild policy is cost-first:

1. serve cached Reader HTML if its cache version is current
2. otherwise reuse Markdown if its version is current
3. otherwise reuse cleaned HTML if its version is current
4. otherwise rerun Readability from stored source HTML
5. otherwise fetch from the network

This makes local debug invalidation awkward because clearing an upstream version alone is not enough if a downstream cache still looks current. It also means an upstream production version bump is not a complete invalidation signal by itself.

Example:

- `readabilityVersion` is stale
- `markdownVersion` is current
- `readerRenderVersion` is current

Under the old policy, the rendered cache can still be served directly. That is not the intended behavior once pipeline versioning is treated as the source of truth.

---

## New Validity Model

### Rule

A layer is reusable only if:

- its own payload exists
- its own version is current
- every upstream layer required to produce it is also current

### Derived validity

For a single entry and theme:

- `cleanedHtml` is valid if:
  - `cleanedHtml` exists
  - `readabilityVersion == ReaderPipelineVersion.readability`
- `markdown` is valid if:
  - cleaned HTML is valid
  - `markdown` exists
  - `markdownVersion == ReaderPipelineVersion.markdown`
- rendered Reader HTML cache is valid if:
  - Markdown is valid
  - cached Reader HTML exists
  - `readerRenderVersion == ReaderPipelineVersion.readerRender`

### Rebuild policy under the new model

The action selection becomes:

1. if rendered cache is valid: `serveCachedHTML`
2. else if Markdown is valid: `rerenderFromMarkdown`
3. else if cleaned HTML is valid: `rebuildMarkdownAndRender`
4. else if source HTML exists: `rerunReadabilityAndRebuild`
5. else: `fetchAndRebuildFull`

### Consequence

For targeted debug rebuilds, clearing one layer's version is enough to invalidate that layer and all downstream layers logically.

Examples:

- Clear `readerRenderVersion` -> only Reader HTML cache becomes invalid.
- Clear `markdownVersion` -> Markdown and Reader HTML cache become invalid.
- Clear `readabilityVersion` -> cleaned HTML, Markdown, and Reader HTML cache all become invalid.

No downstream version clearing is required for correctness once the rebuild policy follows upstream validity.

---

## Debug Menu

### Scope

The Reader toolbar debug control in debug builds becomes a `Menu`, not a single button.

### Initial menu items

- `Show Debug Issues`
- `Re-run Pipeline: All`
- `Re-run Pipeline: Readability`
- `Re-run Pipeline: Markdown`
- `Re-run Pipeline: Reader HTML`

`Show Debug Issues` retains the existing behavior.

### Visibility

- Debug-only
- Reader-only
- Operates on the currently selected entry

---

## Re-run Action Semantics

### `Re-run Pipeline: Reader HTML`

Intent:

- rebuild only the final Reader HTML cache

Data mutation:

- set `content_html_cache.readerRenderVersion = nil` for the current entry

Expected next rebuild action:

- `rerenderFromMarkdown`

Notes:

- the cache payload may remain in the database; it is simply considered invalid
- the rebuild writes a fresh Reader HTML cache on success

### `Re-run Pipeline: Markdown`

Intent:

- rebuild Markdown and the final Reader HTML cache from existing cleaned HTML

Data mutation:

- set `content.markdownVersion = nil` for the current entry

Expected next rebuild action:

- `rebuildMarkdownAndRender`

Notes:

- `markdown` text may remain persisted temporarily
- it must not be treated as reusable while its version is invalid

### `Re-run Pipeline: Readability`

Intent:

- rerun Readability from stored source HTML, then rebuild Markdown and Reader HTML cache

Data mutation:

- set `content.readabilityVersion = nil` for the current entry

Expected next rebuild action:

- `rerunReadabilityAndRebuild` if source HTML is still present
- `fetchAndRebuildFull` if source HTML is absent

Notes:

- this is the primary local-development action when testing a new Readability library build against the same stored article source

### `Re-run Pipeline: All`

Intent:

- force a full end-to-end rebuild, including re-downloading source HTML

Data mutation:

- remove the current entry's `content` row
- remove the current entry's `content_html_cache` rows

Expected next rebuild action:

- `fetchAndRebuildFull`

Notes:

- this action is intentionally different from `Readability`
- if source HTML were preserved, `All` would collapse into the same behavior as `Readability`, which is not acceptable for this menu design

---

## Payload Retention Policy

For version-driven invalidation actions other than `All`:

- old payloads may remain stored
- invalid versions make those payloads non-reusable
- a failed rebuild does not require deleting historical payloads first

This keeps debug operations simple and avoids destructive mutations when a version-only invalidation is sufficient.

`All` is the exception because it is defined as a forced network refetch, not merely a local re-derivation.

---

## AI Feature Coordination

Summary, Translation, and Tagging all depend on Reader pipeline output. They must not run for the current entry while its Reader pipeline is rebuilding.

### Required UI behavior

While the current entry's Reader pipeline is rebuilding:

- disable Summary actions
- disable Translation actions
- disable Tagging actions that depend on article body content

This applies to explicit user actions and any entry-bound auto-trigger behavior.

### Why UI disablement alone is not enough

A rebuilding flag improves UX and prevents concurrent user actions, but it does not fully protect data correctness because:

- a layer may already be invalid before rebuilding starts
- rebuilding may fail, leaving old payloads in storage
- other call sites may read persisted content outside the immediate Reader UI flow

Therefore the data-access layer must also enforce validity.

---

## Markdown Access Contract

The current helper `summarySourceMarkdown(entryId:)` is too permissive if it returns persisted Markdown solely because the string exists.

Under the new contract, shared Markdown access must return Markdown only when it is currently valid.

### Required condition for shared Markdown access

`summarySourceMarkdown(entryId:)` or its replacement should return Markdown only if:

- `markdown` exists and is non-empty
- `markdownVersion == ReaderPipelineVersion.markdown`
- `readabilityVersion == ReaderPipelineVersion.readability`

This ensures that downstream features do not consume logically invalid Markdown merely because stale text is still persisted.

### Shared-call-site implication

Any feature that uses Reader-derived Markdown must route through the shared validity-aware accessor instead of reading `content.markdown` directly.

This includes:

- Summary source resolution
- Translation source segmentation
- Tagging-panel body generation

---

## Reader Rebuild Runtime Contract

For an explicit debug-triggered re-run on the current entry:

1. mark the current entry's Reader pipeline as rebuilding
2. apply the requested invalidation
3. clear the visible Reader HTML state for the current view
4. invoke the existing Reader build path
5. update the visible Reader content from the new result
6. clear the rebuilding state

If rebuild fails:

- keep the failure visible through existing Reader failure handling and Debug Issues reporting
- clear the rebuilding state
- do not treat previously persisted but invalid payloads as reusable content

---

## Proposed Implementation Structure

### Data layer

Add a focused invalidation API in `ContentStore` for debug use:

- version-only invalidation for:
  - Readability
  - Markdown
  - Reader HTML cache
- destructive invalidation for:
  - All

The API should operate on one entry at a time and keep mutation semantics explicit.

### Runtime / model layer

Add an app-level Reader debug orchestration entry point that:

- validates the selected entry
- calls the appropriate content-store invalidation
- records debug issues on failure
- drives a rebuild for the current Reader view

### View layer

Replace the current debug toolbar button with a `Menu` in debug builds.

The menu should:

- preserve `Show Debug Issues`
- expose the four re-run actions
- disable re-run actions while the current entry is rebuilding

### Shared content access

Refine shared Reader-derived Markdown access so it is validity-aware.

Tagging must stop reading `content.markdown` directly and use the shared accessor.

---

## Edge Cases

### Readability re-run without stored source HTML

If `readabilityVersion` is invalid but `content.html` is absent:

- the rebuild must fall back to `fetchAndRebuildFull`

This is acceptable and consistent with the new policy.

### Rebuild failure after version invalidation

If a rebuild fails after version invalidation:

- invalid versions remain invalid
- historical payload text may remain physically present
- downstream consumers must still reject those payloads through validity checks

### Theme-specific Reader HTML cache

Reader HTML cache invalidation is per entry and per theme cache identity. The debug semantics should remain explicit:

- version-only invalidation may set `readerRenderVersion = nil` on all cache rows for the entry
- `All` removes all cache rows for the entry

Using all theme rows keeps the debug action predictable and avoids stale cross-theme render artifacts.

---

## Acceptance Criteria

- The Reader toolbar debug control becomes a menu in debug builds.
- `Show Debug Issues` remains available from that menu.
- The menu contains `Re-run Pipeline: All`, `Readability`, `Markdown`, and `Reader HTML`.
- `Re-run Pipeline: Reader HTML` invalidates only Reader HTML cache reusability.
- `Re-run Pipeline: Markdown` invalidates Markdown and all downstream reusability.
- `Re-run Pipeline: Readability` invalidates Readability and all downstream reusability.
- `Re-run Pipeline: All` forces a network refetch by removing stored source HTML together with downstream cache records.
- Rebuild policy no longer treats a downstream layer as reusable when an upstream layer is invalid.
- Summary, Translation, and Tagging are disabled for the current entry while its Reader pipeline is rebuilding.
- Shared Markdown access rejects invalid persisted Markdown.
- Tagging no longer reads `content.markdown` directly.
- Reader rebuild failures continue to surface through existing error and Debug Issues paths.

---

## Verifiable Step-by-Step Implementation Plan

### Step 1: Rebuild policy unification

Change:

- update `ReaderRebuildPolicy` so downstream validity depends on upstream validity

Verification:

- add or update unit tests covering:
  - stale `readabilityVersion` invalidates Markdown and Reader HTML cache reuse
  - stale `markdownVersion` invalidates Reader HTML cache reuse
  - stale `readerRenderVersion` still allows `rerenderFromMarkdown`
- remove or rewrite tests that encode the old cost-first downstream reuse behavior

Exit criteria:

- the test suite expresses the new layered validity model unambiguously

### Step 2: Debug invalidation API

Change:

- add targeted pipeline invalidation methods in `ContentStore`
- support:
  - set `readerRenderVersion = nil`
  - set `markdownVersion = nil`
  - set `readabilityVersion = nil`
  - delete `content` plus `content_html_cache` for `All`

Verification:

- add database-level tests that assert exact row mutations for each action
- confirm `All` removes stored source HTML, while version-only actions do not

Exit criteria:

- each debug action has one explicit, tested persistence mutation path

### Step 3: Shared Markdown validity gate

Change:

- make shared Markdown access version-aware
- route Tagging, Summary, and Translation source resolution through that shared gate

Verification:

- add tests showing:
  - valid Markdown is returned
  - invalid Markdown is rejected when `markdownVersion` is stale
  - invalid Markdown is rejected when `readabilityVersion` is stale

Exit criteria:

- no feature can consume logically invalid Reader-derived Markdown through shared accessors

### Step 4: Reader rebuild state and AI disabling

Change:

- track rebuilding state for the current Reader entry
- disable Summary, Translation, and Tagging actions during rebuild

Verification:

- view-model or UI behavior tests confirm actions are disabled while rebuild is in progress
- manual verification confirms the toolbar and related action surfaces cannot start those features mid-rebuild

Exit criteria:

- entry-bound AI actions are blocked during Reader pipeline rebuild

### Step 5: Debug menu wiring

Change:

- replace the Reader debug button with a menu
- add `Show Debug Issues` and the four `Re-run Pipeline` items
- wire each item to the new invalidation + rebuild flow

Verification:

- manual debug-build verification:
  - open an article
  - trigger each menu action
  - observe that the expected rebuild path runs
  - confirm `All` performs a refetch rather than a local-only rebuild

Exit criteria:

- the Debug menu is usable as the primary local pipeline-testing surface

### Step 6: End-to-end validation

Change:

- run the focused tests added above
- run the repository build

Verification:

- `./scripts/build` completes without warnings
- the Reader still opens articles correctly after each debug action
- Summary, Translation, and Tagging resume normal operation after rebuild completes

Exit criteria:

- the new debug pipeline controls are production-safe for debug builds and match the documented semantics

---

## Recommended Implementation Order

1. Rebuild policy
2. Debug invalidation API
3. Shared Markdown validity gate
4. Rebuild state and AI disablement
5. Debug menu wiring
6. End-to-end validation

This order keeps the semantics correct before UI work begins and prevents the menu from exposing actions that still rely on outdated cache contracts.
