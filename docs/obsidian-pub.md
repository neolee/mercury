# Obsidian Publish Support in Mercury

## Background

Mercury's current Reader pipeline is:

```text
source HTML -> Readability -> cleanedHtml -> markdown -> reader HTML
```

This works for normal article pages where the fetched HTML already contains the article body.

Some sites built on Obsidian Publish do not serve the article body directly in the initial HTML. The fetched page is only a bootstrap shell, and the actual article Markdown is loaded dynamically by the client.

Example:

- feed: `https://chadnauseam.com/rss.xml`
- page: `https://chadnauseam.com/coding/tips/give-them-two-choices`

For this sample, the fetched `source.html` contains only an Obsidian Publish shell and a static `window.preloadPage = fetch("...md")` declaration. The article body is not present in the HTML body, so `Readability` fails for the expected reason.

## Problem Statement

This is not a `Readability` heuristic problem.

It is a source-resolution problem that happens after Mercury has fetched `source HTML` but before the default `Readability` stage can succeed.

Therefore, support for Obsidian Publish should be implemented as a special Reader pipeline type that can take over after `source HTML` has been fetched.

## Agreed Product Scope

Mercury should support only the narrow subset needed to display the article content cleanly in Reader mode.

Supported goal for v1:

- detect an Obsidian Publish shell page with high confidence
- statically extract the real Markdown URL
- fetch the Markdown directly
- store and render the article content cleanly in Reader mode

Explicit non-goals for v1:

- no WebView-based page hydration
- no arbitrary JavaScript execution
- no generic SPA rendering framework
- no attempt at full Obsidian visual fidelity
- no broad support for all Obsidian-specific syntax

If static resolution fails, Mercury should fall back to the default Reader pipeline and accept failure on unsupported pages.

## Sample Evidence: Chad Nauseam

The sample shell page contains stable Obsidian Publish markers:

- `<base href="https://publish.obsidian.md">`
- `window.siteInfo = { ... }`
- `window.preloadPage = fetch("https://publish-01.obsidian.md/access/.../give-them-two-choices.md")`

This confirms that the page can be handled by static analysis alone.

## Agreed Architectural Direction

### 1. Reader pipeline types become first-class

Mercury should introduce an explicit Reader pipeline type.

Approved direction:

- add `content.pipelineType`
- default value is `default`
- current special value is `obsidian`

This value represents which Reader pipeline owns the persisted content row.

It should live on `content`, not `entry`, because it belongs to the persisted Reader build state rather than to the entry's permanent identity.

### 2. Keep the existing default pipeline semantics intact

The default pipeline remains:

```text
source HTML -> Readability -> cleanedHtml -> markdown -> reader HTML
```

`cleanedHtml` must keep its current meaning:

- it is the cleaned HTML produced by `Readability.parse()`
- it is not a generic scratch field
- it must not be reused for special-pipeline resolver metadata

### 3. Add one generic special-pipeline intermediate field

Approved new field:

- `content.resolvedIntermediateContent`

This field is reserved for pipeline-specific intermediate state.

Rules:

- it is interpreted by the owning pipeline type
- the default pipeline should not depend on it
- in the Obsidian pipeline, its initial value is the resolved Markdown URL

No other new fields are approved at this stage. If more fields are later found necessary, they require explicit discussion first.

### 4. Special pipelines integrate at fixed Reader pipeline stages

The goal is not to bolt on one-off site handlers.

Instead, the Reader pipeline should expose a fixed set of pipeline-stage integration points. Each pipeline type then provides its own implementation for those stages.

This makes the framework impact explicit and stable:

- `ReaderDefaultPipeline`
- `ReaderObsidianPipeline`

Both pipelines conform to the same stage-oriented interface. The interface names should describe the pipeline entry point, not the implementation detail.

At the current design stage, the agreed split is:

- pipeline resolution is handled by a shared `ReaderPipelineResolver`
- pipeline-specific rebuild policy is implemented by each pipeline type
- pipeline-specific Markdown construction is implemented by each pipeline type
- final `markdown -> reader HTML` rendering remains shared

### 5. Shared final rendering should remain shared

Once canonical Markdown is available, Mercury should continue to use the shared rendering path:

```text
markdown -> reader HTML
```

The final render/cache stage should stay shared unless a future pipeline proves that it truly needs a different renderer.

For the Obsidian v1 scope, the final rendering stage should remain unchanged.

## Agreed Interface Boundary

The following boundary is now agreed for this iteration.

### Shared framework responsibilities

These responsibilities stay in the shared Reader framework rather than becoming pipeline hooks:

- `resolve`
- network fetch of the entry URL
- final `markdown -> reader HTML` rendering and cache write

Current rationale:

- `resolve` should be centralized in `ReaderPipelineResolver`
- fetch remains a shared acquisition concern
- final rendering is intentionally shared once canonical Markdown exists

At this stage, these three steps do not need pipeline-specific extension points.

### Shared resolver

Introduce a dedicated shared resolver:

- `ReaderPipelineResolver`

Responsibility:

- inspect freshly fetched source HTML
- decide which `ReaderPipelineType` owns the row
- initialize pipeline-specific persisted state such as `resolvedIntermediateContent`

This is a shared decision point, not a method implemented separately by each pipeline class.

### Pipeline-specific interface

Each pipeline type should provide the following common interface surface:

- `rebuildAction(for:)`
- `buildMarkdownFromSource(...)`
- `buildMarkdownFromIntermediate(...)`

Meaning:

- `rebuildAction(for:)`
  - decides which persisted layer is reusable and what rebuild path is needed next
- `buildMarkdownFromSource(...)`
  - builds canonical Markdown from persisted source HTML in `content.html`
  - this is used both after a fresh fetch has been resolved and during later rebuilds from stored source
- `buildMarkdownFromIntermediate(...)`
  - builds canonical Markdown from the pipeline's own persisted intermediate layer
  - for `default`, the intermediate is `cleanedHtml`
  - for `obsidian`, the intermediate is `resolvedIntermediateContent`

### Why there is no separate `buildMarkdownFromFetchedSource(...)`

This was considered and then rejected.

Reason:

- once `ReaderPipelineResolver` has already resolved the pipeline type and initialized persisted state, the pipeline class no longer needs to distinguish whether `content.html` came from a fresh fetch or from stored content
- both cases can use the same `buildMarkdownFromSource(...)` entry point

This keeps the pipeline interface smaller and avoids a redundant stage hook.

## Pipeline Model

### Default

```text
source HTML
-> Readability
-> cleanedHtml
-> markdown
-> reader HTML
```

### Obsidian

```text
source HTML
-> resolve Markdown URL
-> fetch Markdown
-> markdown
-> reader HTML
```

Notes:

- the fetched shell HTML still remains the persisted `source HTML`
- the resolved Markdown URL is stored in `resolvedIntermediateContent`
- `cleanedHtml` remains empty for this path unless a later design explicitly gives it a different legitimate upstream source

## Detection Rules for Obsidian Publish

Detection should be intentionally narrow and high-confidence.

Expected markers include:

- `<base href="https://publish.obsidian.md">`
- `window.siteInfo = { ... }`
- `window.preloadPage = fetch("...")`
- asset URLs under `publish-01.obsidian.md/access/...`

The resolver should not rely on fuzzy similarity heuristics when static exact markers are available.

## Fallback Policy

If any Obsidian-specific step fails, Mercury should stop special handling and fall back to the default Reader pipeline.

Typical failure conditions:

- the shell page is not recognized confidently
- no static Markdown URL can be extracted
- the resolved Markdown URL fetch fails
- the fetched content is empty or obviously invalid

Fallback behavior:

- keep the fetched `source HTML`
- leave `pipelineType` as `default` unless the special pipeline completed enough work to own the row coherently
- continue through the normal Reader path

## Reader Debug Semantics

The Debug menu is developer-facing, so it may have pipeline-type-specific behavior as long as the rules are explicit.

Important rule:

- pipeline-specific rebuild semantics must be documented and deterministic

Examples:

- for `default`, a Readability rebuild means re-running `Readability`
- for `obsidian`, the equivalent rebuild means rebuilding according to the Obsidian pipeline's own `rebuildAction(for:)` rules

Developer ergonomics are acceptable as long as the meaning stays explicit.

## Base URL and Media Considerations

Obsidian Markdown may contain links or media references that are not immediately safe to render as-is.

The implementation review must explicitly decide whether the special pipeline needs one or both of:

- normalization of links and media URLs before final Markdown persistence
- a pipeline-provided base URL for Reader HTML display

Current agreement:

- this concern must be handled consciously during implementation
- it does not yet justify adding another public pipeline interface hook
- the first implementation should prefer solving it inside pipeline Markdown construction if possible

If later implementation proves that a dedicated base-URL or media-normalization interface is necessary, that requires a new design discussion first.

## Current Design Constraints

The following constraints are now fixed for this iteration:

- support is implemented as a formal Reader pipeline type, not a one-off site hack
- `cleanedHtml` keeps its `Readability`-owned meaning
- `content.pipelineType` is required
- `content.resolvedIntermediateContent` is allowed
- no additional new fields may be added without explicit confirmation
- interface names should be stage-oriented and pipeline-oriented
- v1 scope is limited to clean article display, not full Obsidian fidelity

## Implementation Plan

The implementation should proceed in a small number of steps where each step produces an independently verifiable result.

### Step 1. Add persisted pipeline identity and shared resolution

Change:

- add `content.pipelineType`
- add `content.resolvedIntermediateContent`
- introduce `ReaderPipelineResolver`
- resolve fetched source HTML into `default` or `obsidian`
- initialize `resolvedIntermediateContent` for Obsidian with the resolved Markdown URL

Verification:

- migration tests confirm both new columns exist
- existing rows still read correctly with nil or default values
- resolver tests cover the Chad Nauseam shell sample, normal pages, and fallback cases

### Step 2. Introduce pipeline-specific rebuild and Markdown construction

Change:

- add `ReaderDefaultPipeline` and `ReaderObsidianPipeline`
- define the common pipeline interface
- implement `rebuildAction(for:)`
- implement `buildMarkdownFromSource(...)`
- implement `buildMarkdownFromIntermediate(...)`

Verification:

- unit tests confirm `default` preserves current rebuild semantics
- unit tests confirm `obsidian` rebuild semantics derive from `pipelineType` and `resolvedIntermediateContent`
- Reader pipeline versioning tests are updated or extended to cover both pipeline types

### Step 3. Refactor shared Reader build flow to dispatch by pipeline type

Change:

- keep fetch and final `markdown -> reader HTML` rendering shared
- route rebuild policy and Markdown construction through the resolved pipeline type
- remove the hard-coded assumption that all Markdown must come from `Readability -> cleanedHtml`

Verification:

- unit tests confirm fresh fetch path chooses the expected pipeline and produces canonical Markdown
- unit tests confirm rebuild from stored source uses the persisted pipeline type
- existing default Reader behavior remains unchanged under test

### Step 4. Finish Obsidian v1 behavior and debug semantics

Change:

- implement the Obsidian Markdown fetch-and-build path end to end
- validate basic links and media behavior needed for readable article display
- align Debug rebuild actions with pipeline-specific `rebuildAction(for:)` behavior

Verification:

- unit tests confirm Markdown URL extraction, Markdown fetch, and failure behavior
- focused tests cover representative link or media cases if normalization is needed
- a manual run on the Chad Nauseam sample produces readable Reader output and deterministic debug rebuild behavior
