# Note and Sharing Feature Plan

## Overview

This document defines the v1.4 design baseline for four user-facing phases:

1. `Entry Note`
2. `Single-entry Text Share`
3. `Single-entry Markdown Export`
4. `Multiple-entry Markdown Export`

These phases are intentionally incremental. Each phase must produce a complete, verifiable outcome with:

- unit tests
- manual validation steps
- user-visible functionality that is independently useful

This feature set is centered on the user's own notes and commentary. It is **not** an AI synthesis project. Existing summary data may be reused where appropriate, but multi-entry LLM aggregation is out of scope for v1.4.

---

## Product Terms

Use the following product terms consistently in code, UI, and documentation:

- **Share Digest**: single-entry, plain-text output, sent through macOS share services
- **Export Digest**: single-entry, Markdown output, written to the configured local export directory
- **Export Multiple Digest**: multiple-entry, Markdown output, written to the configured local export directory

The word "digest" is the shared product concept for all three output flows.

For concise UI labels, the export actions may omit the trailing `to File` wording:

- `Share Digest...`
- `Export Digest...`
- `Export Multiple Digest...`

---

## Fixed Scope Decisions

### What this feature set includes

- Per-entry user note in simple Markdown text
- Single-entry plain-text share
- Single-entry Markdown export
- Multiple-entry Markdown export
- Template-driven output with built-in defaults and future customization support

### What this feature set does not include

- Multi-entry LLM summarization or editorial synthesis
- Queueing multiple entries into one agent request
- AI-generated digest introductions or grouping
- Replacing the user's own note/commentary with AI-authored content

---

## Shared Design Principles

### UI-first product design

This feature set is primarily UI-driven. Existing architecture is a weak constraint. If the current structure does not support a strong Mercury-quality interaction model, refactoring is allowed and expected after careful evaluation.

The UX target is:

- strong default flow
- minimal friction for common actions
- direct interaction near the content
- opt-in customization for advanced users

### Shared composition pipeline

Although the feature is delivered in four phases, the design should converge on one shared digest-composition pipeline:

- collect source content
- resolve optional note / summary content
- select a template
- render preview text
- deliver through share service or file export

This shared pipeline should be reused across the later phases instead of building separate one-off formatters.

For single-entry share / export sheets, note and summary editing should reuse the existing feature capabilities rather than introduce reduced-function duplicates:

- note editing in a digest sheet should reuse the same persistence model and editing semantics as the Reader note panel
- summary generation in a digest sheet should reuse the same runtime behavior, settings, parameter controls, and persistence model as the Reader summary panel
- digest sheets may reorganize layout for the share / export task, but the underlying summary and note behavior should remain the same feature, not a second subsystem

Implementation note:

- during incremental delivery, separate share / export sheet view models are acceptable if that keeps each phase smaller and safer
- after the user-facing phases are complete, duplicated single-entry digest sheet glue should be consolidated into shared helpers rather than left to drift
- likely shared areas include:
  - single-entry digest projection loading
  - note draft lifecycle and persistence coordination
  - digest template loading and render-failure reporting
  - digest-hosted summary slot projection and refresh wiring
  - sheet-local copy / share / export preparation hooks

### Required content invariants

All digest outputs must always include:

- original article title
- original article author
- original article URL

These fields are mandatory across all three output modes.

Field resolution and fallback policy:

- if article title is missing, the digest cannot be composed; share / export must be disabled
- if article URL is missing, the digest cannot be composed; share / export must be disabled
- if article author is missing, use the feed title as the author fallback when available

---

## Data Model

### Entry note storage

`Entry Note` should use a dedicated table instead of extending `entry`.

Suggested table:

- `entry_note`
  - `entryId`
  - `markdownText`
  - `createdAt`
  - `updatedAt`

Rationale:

- note lifecycle is distinct from feed-ingested entry data
- future note-specific query and export behavior stays clean
- empty-note deletion rules are easier to enforce consistently

---

## Shared Reader Panel Behavior

The new `Note` panel should not introduce another bespoke floating-panel behavior.

Current and future Reader toolbar popover-like panels should converge on one shared interaction model:

- toolbar button toggles panel show / hide
- only one such panel is visible at a time
- clicking inside the panel keeps it open
- clicking outside closes it
- `Esc` closes it
- changing the selected entry closes it

This shared host behavior should be extracted and reused by:

- theme panel
- tagging panel
- note panel
- future Reader-side utility panels if needed

The panel implementation does not need to be visually identical, but the open / close lifecycle should be unified.

---

## Templates

### Built-in template location

Built-in digest templates should live under:

- `Resources/Digest/Templates/`

Initial built-ins:

- `single-text.yaml`
- `single-markdown.yaml`
- `multiple-markdown.yaml`

### Template store

Create a dedicated `DigestTemplateStore` or similarly named component for sharing/export templates.

Hard requirement:

- it must share the core parsing / placeholder / override logic with `AgentPromptTemplateStore`
- it must not copy that logic into a second unrelated implementation

The two stores may diverge in schema and validation rules, but they should share the underlying template-processing core.

### Template syntax baseline

Digest templates should use a minimal section-based syntax that is easy to implement and easy to read.

Approved baseline syntax:

- scalar placeholder: `{{name}}`
- section block: `{{#name}} ... {{/name}}`

Digest templates should declare loop-style sections explicitly when needed:

- repeated section declaration: `repeatedSectionNames`
- example: `entries` for `multiple-markdown.yaml`

Section semantics:

- when `name` resolves to a boolean-like truthy value, the section renders conditionally
- when `name` resolves to a list, the section renders once per item in the list
- inside a repeated section, placeholders resolve against the current item first, then outer scope if needed

Examples:

- conditional summary block: `{{#includeSummary}} ... {{/includeSummary}}`
- repeated entry block: `{{#entries}} ... {{/entries}}`

Contract note:

- list section names remain a shared code/template contract
- the template must declare them explicitly via `repeatedSectionNames`
- the renderer must require the corresponding repeated-section input at render time

This syntax is intentionally Mustache-like, but only the minimum subset needed by Mercury should be implemented.

### Customization direction

v1.4 only needs strong built-in defaults plus an architecture that can support customization.

Early customization requirements:

- built-in templates remain the default
- user overrides should be possible later without redesigning the storage model
- Digest-related settings should have a stable place in app settings from Phase 3 onward

### Export filename baseline

Exported Markdown filenames should follow a shared default rule and remain customizable through digest template customization in the future.

#### Single-entry Markdown export

- default digest title: original article title
- filename format: `yyyy-mm-dd-<slug>.md`
- date source: local export date, not article publish date
- slug source: normalized digest title

Slug normalization baseline:

- trim leading and trailing whitespace
- preserve CJK characters, letters, and numbers
- convert spaces and common separators to `-`
- remove filesystem-hostile characters
- lowercase ASCII letters
- collapse repeated `-`
- trim leading and trailing `-`
- truncate to a moderate length if needed

If slug generation produces an empty result:

- use `digest`

#### Multiple-entry Markdown export

- default digest title: `推荐阅读（YYYY年MM月DD日）`
- default slug: `digest`
- filename format: `yyyy-mm-dd-digest.md`
- date source: local export date

#### Name collision policy

When a target filename already exists, append a numeric suffix:

- `-2`
- `-3`
- and so on

Examples:

- `2026-03-29-reader-pipeline-debugging.md`
- `2026-03-29-数据库与缓存设计.md`
- `2026-03-29-digest.md`
- `2026-03-29-digest-2.md`

This collision behavior is automatic. Users may later merge, rename, or remove files manually in their content repository.

---

## Built-in Template Baseline

The initial three built-in templates should be intentionally simple, publication-friendly, and aligned with the Hugo-based workflow recommended for Mercury users.

### Shared Markdown template principles

- use TOML front matter with `+++`
- keep front matter minimal and stable
- render body structure with as few headings and labels as practical
- preserve user-authored note Markdown as-is
- localize fixed labels and explanatory copy at least in Chinese and English
- plain-text template may keep the inline word `by` untranslated

### Shared Markdown front matter baseline

The default Markdown templates should start with:

```toml
+++
date = '{{exportDateTimeISO8601}}'
draft = false
title = '{{digestTitle}}'
slug = '{{fileSlug}}'
+++
```

The built-in baseline intentionally omits optional front matter fields such as:

- `tags`
- `summary`

These may be added later by template customization.

### `single-text.yaml`

Purpose:

- ultra-compact plain-text output for system share targets
- optimized for direct sending rather than structured publishing

Built-in template:

```text
{{articleTitle}} by {{articleAuthor}} {{articleURL}}{{#includeNote}} {{noteText}}{{/includeNote}}
```

Rules:

- always include title, author, and URL
- never include summary
- note is appended inline only when enabled and non-empty
- `noteText` should use the persisted note content with no extra formatting normalization by default
- length is not auto-managed; user may edit manually if the result is too long

### `single-markdown.yaml`

Purpose:

- single-entry Markdown export suitable for Hugo content repositories

Body structure:

1. front matter
2. source line
3. author line
4. optional summary blockquote
5. optional note block introduced inline by bold `Note` label

Built-in template:

```md
+++
date = '{{exportDateTimeISO8601}}'
draft = false
title = '{{digestTitle}}'
slug = '{{fileSlug}}'
+++

**{{labelSource}}**: [{{articleTitle}}]({{articleURL}})
**{{labelAuthor}}**: {{articleAuthor}}

{{#includeSummary}}
> {{summaryTextBlockquote}}
>
> - {{labelSummaryGeneratedByPrefix}} [Mercury Summary Agent](https://github.com/neolee/mercury) {{labelSummaryGeneratedBySuffix}} (`{{summaryTargetLanguage}}`, `{{summaryDetailLevel}}`)
{{/includeSummary}}

{{#includeNote}}
**{{labelNote}}**：{{noteText}}
{{/includeNote}}
```

Rules:

- summary explanatory line appears after the summary content, not before it
- summary explanatory line includes a link to the Mercury homepage
- summary parameters stay in a compact raw form
- `noteText` should preserve the user's stored Markdown as-is
- the template simply prefixes the note with a bold note label

### `multiple-markdown.yaml`

Purpose:

- multiple-entry Markdown export for one digest-style post

Body structure:

1. front matter
2. repeated entry sections
3. each entry uses plain-text `h2` title for separation
4. URL and author are shown on separate lines
5. optional summary blockquote
6. optional note block introduced inline by bold `Note` label

Built-in template:

```md
+++
date = '{{exportDateTimeISO8601}}'
draft = false
title = '{{digestTitle}}'
slug = '{{fileSlug}}'
+++

{{#entries}}
## {{articleTitle}}

**{{labelSource}}**: [{{articleURL}}]({{articleURL}})
**{{labelAuthor}}**: {{articleAuthor}}

{{#includeSummary}}
> {{summaryTextBlockquote}}
>
> - {{labelSummaryGeneratedByPrefix}} [Mercury Summary Agent](https://github.com/neolee/mercury) {{labelSummaryGeneratedBySuffix}} (`{{summaryTargetLanguage}}`, `{{summaryDetailLevel}}`)
{{/includeSummary}}

{{#includeNote}}
**{{labelNote}}**：{{noteText}}
{{/includeNote}}
{{/entries}}
```

Rules:

- do not use linked `h2` headings
- do not add extra horizontal rules between entries
- section separation comes from the `h2` structure itself
- URL and author remain explicit and readable under each title

### Localized fixed labels

At minimum, built-in templates should localize these fixed labels:

- `labelSource`
- `labelAuthor`
- `labelNote`
- `labelSummaryGeneratedByPrefix`
- `labelSummaryGeneratedBySuffix`

Suggested built-in Chinese values:

- `原文`
- `作者`
- `点评`
- `由`
- `生成`

Suggested built-in English values:

- `Source`
- `Author`
- `Note`
- `generated by`
- ``

The summary explanatory sentence is therefore expected to render as:

- Chinese: `- 由 Mercury Summary Agent 生成（参数）`
- English: `- generated by Mercury Summary Agent (parameters)`

The exact punctuation and parameter-wrapping syntax may be handled by the template or renderer, but the built-in output should preserve this compact style.

---

## Phase 1: Entry Note

### Entry point

- new `Note` button in the Reader toolbar

### Interaction

- opens a lightweight floating panel near the toolbar
- supports direct Markdown text editing
- designed for quick capture of personal thoughts / commentary

### Persistence status

`Entry Note` uses auto-save semantics, but persistence and empty-record deletion are treated as two different concerns.

#### Editing model

- the panel edits an in-memory `draft`
- the editor is not directly bound to the database row
- the implementation should track both:
  - `persistedText`
  - `draftText`

#### Auto-save / flush policy

- note content should auto-flush after `5s` of inactivity
- flush should also run immediately on:
  - panel close
  - entry switch
  - app / window backgrounding lifecycle
  - note consumption for share / export flows

Flush only handles persistence of non-empty content:

- if normalized note content is non-empty and changed from the persisted value, write or update it
- if normalized note content is empty, flush does nothing

#### Empty-note deletion policy

Deleting an empty note record is more precise than auto-flush and should happen only at note-lifecycle boundaries.

Empty-note deletion should be evaluated only on:

- panel close
- entry switch

Rules:

- if normalized note content is empty and a persisted note exists, delete the note row
- if normalized note content is empty and no persisted note exists, do nothing
- do not delete note rows during normal timed auto-flush
- do not delete note rows during background-triggered flush
- do not delete note rows during share / export-triggered flush

This means one accepted edge case remains:

- if the user clears a note but leaves the panel open, and the app exits unexpectedly before close or entry switch, the previous persisted note may remain in storage

This behavior is acceptable for v1.4 because it is safer than deleting content too aggressively during active editing.

#### Normalization boundary

Normalization is used only to determine persistence / deletion behavior.

- content that trims to empty is treated as empty
- normal Markdown formatting should otherwise be preserved as entered
- persistence comparison should avoid unnecessary writes when content has not materially changed

#### UI save-state feedback

The note panel should expose lightweight but clear save-state feedback:

- `Saving...`
- `Saved`

This should remain subtle, but visible enough to confirm that the panel is auto-saving user input.

### Phase 1 acceptance targets

- note can be created, edited, reopened, and removed
- switching entries keeps note state correct
- empty note cleanup behavior is deterministic
- save-state feedback is visible and accurate
- Reader panel behavior matches the shared panel contract

---

## Phase 2: Single-entry Text Share

### Product name

- `Share Digest`

### Entry point

- add a new item under the existing Reader `Share` menu

### Output mode

- plain text only
- delivered via macOS share services

### Required content

- title
- author
- URL

### Optional content

- note

### Note editing behavior

For single-entry text share:

- the sheet may include or exclude note content
- note editing in the sheet is full-function note editing, not a temporary preview-only field
- sheet edits should persist through the same note storage path used by the Reader note panel
- if note is missing, the user may create it in place inside the sheet
- if note already exists, the user may continue editing it in place inside the sheet

### UX shape

This should use a dedicated sheet:

- configure included fields
- preview the rendered plain text
- trigger system share from the generated result

---

## Phase 3: Single-entry Markdown Export

### Product name

- `Export Digest...`

### Entry point

- add a new item under the existing Reader `Share` menu

### Output mode

- Markdown only
- written to the configured local export directory

### Required content

- title
- author
- URL

### Optional content

- summary
- note

### Summary behavior

For single-entry Markdown export:

- summary may be included
- if a persisted summary already exists, it can be used directly
- if no summary exists, the user may generate one in place inside the export sheet
- summary generation must reuse existing summary panel logic and runtime behavior instead of creating a second summary subsystem
- in-sheet summary generation remains full-function summary generation:
  - the user may adjust summary parameters
  - the user may regenerate summary content
  - generation and persistence should follow the same behavior as the Reader summary panel

### Note behavior

For single-entry Markdown export:

- note may be included
- note editing in the sheet is full-function note editing, not a temporary preview-only field
- sheet edits should persist through the same note storage path used by the Reader note panel
- if note is missing, the user may create it in place inside the export sheet
- if note already exists, the user may continue editing it in place inside the export sheet

### Non-editable generated fields

In single-entry share / export sheets, fields that come from source metadata or digest composition are previewed but not edited in the sheet.

This includes:

- article title
- resolved author text
- article URL
- digest title
- export filename / slug preview

Only note and summary are interactive editing / generation surfaces inside digest sheets.

### Settings dependency

Before or as part of Phase 3, App Settings must gain a new dedicated tab:

- `Digest`

Initial contents must include:

- `Local Export Path`

This tab is the stable future home for:

- local export path
- template customization controls
- future digest-related settings

The export sheet itself should **not** allow editing the export path directly. Instead it may provide a shortcut to open App Settings and jump to the `Digest` tab.

This implies a reusable app-settings navigation contract rather than one-off `openSettings()` calls.

Recommended direction:

- feature UIs should be able to open App Settings with an optional target tab
- `Digest` is the first concrete consumer
- later `Agents` and other tabs should reuse the same navigation helper instead of inventing separate routing behavior
- if a future settings destination needs deeper positioning than tab level, that should extend the same navigation contract instead of bypassing it

If `Local Export Path` is missing or invalid:

- export actions that require file output should be disabled
- the UI should provide a direct shortcut to open App Settings and complete or repair the path
- the settings window may be opened and used in parallel while the export sheet remains present

Export-path validation policy:

- the app should validate export-path availability at export time
- the `Digest` settings tab does not need eager runtime validation
- the settings UI should provide clear explanatory tips, but not attempt to act as a live path-health monitor

### Phase 3 acceptance targets

- `Digest` settings tab exists and includes `Local Export Path`
- export sheet can open `Digest` settings without dismissing itself
- export preview shows non-editable source and filename fields correctly
- summary generation in the export sheet reuses the existing summary runtime and persistence path
- note editing in the export sheet reuses the existing note persistence path
- Markdown preview and exported file content are template-driven and stay in sync
- export filename and collision suffix behavior are deterministic

### Phase 3 closeout status

Phase 3 is complete and validated.

Automated validation:

- `./scripts/build`
- `./scripts/test`

Manual validation covered:

- `Settings > Digest` path selection, reveal, clear, and in-place routing from the export sheet
- summary generation and persistence reuse, including refresh of the Reader summary panel after in-sheet generation
- note editing and persistence reuse between the export sheet and Reader note panel
- template-driven Markdown preview, copy, and export behavior
- export-path-disabled state for `Export`, while `Copy` remains available
- filename generation, slugging, and collision suffix behavior
- author fallback chain: `entry.author -> readabilityByline -> feed title -> empty`

---

## Phase 4: Multiple-entry Markdown Export

### Product name

- `Export Multiple Digest...`

### Entry point

- add a new item in the Entry List header menu
- do not place the primary entry point inside the Reader `Share` menu

### Output mode

- Markdown only
- written to the configured local export directory

### Required content per entry

- title
- author
- URL

### Optional content per entry

- summary
- note

### Summary and note rules

For multiple-entry export:

- summary inclusion is optional
- note inclusion is optional
- no in-place summary generation
- no in-place note editing
- if a selected field is missing on an entry, output should simply omit that content for that entry

### Selection flow

Multiple-entry export should use a dedicated list selection mode.

Recommended interaction:

- user chooses `Export Multiple Digest...` from the Entry List menu
- Entry List enters a temporary multi-select mode with checkboxes
- the list header changes to a mode-specific control strip
- user confirms selection and opens the export sheet

Selection mode contract:

- the mode exists only to collect a small set of entry IDs and then exit
- entering the mode freezes the surrounding list / Reader state
- while active, the app should not:
  - load additional entries
  - change the currently displayed entry
  - mutate unrelated surrounding state
- exiting the mode should not alter the previously selected Reader entry

Any unrelated navigation or filtering action should implicitly exit multi-select mode, including:

- switching feed
- changing tag selection
- changing read / unread filtering
- changing search scope or other query-defining controls

### Export order

Multiple-entry digest output should follow the current Entry List order.

Hard rule:

- do not preserve checkbox click order as export order
- exported entry order should match the visible list ordering active at the time selection is confirmed

### Selection constraints

This mode is intended for a small number of entries.

Working assumptions:

- selecting more than 5 entries is abnormal for this workflow
- the product should guide users toward smaller, intentional selections
- existing feed / tag / unread / search filters are the primary way to narrow candidates before entering selection mode
- this is a design guideline only, not a hard product limit

### Digest title editing

For multiple-entry export, the built-in digest title should be generated automatically and shown in preview, but not edited in the export sheet.

If users want a custom title, they can change it after export in the generated Markdown file.

### Loading behavior in selection mode

Do not support `Load More` or infinite-scroll continuation in multi-select export mode.

Rationale:

- the workflow is intentionally small-batch
- expanding the candidate list mid-selection adds interaction ambiguity
- the existing filtering model already provides the preferred way to narrow the working set

---

## Phase 5: Digest Architecture Consolidation

### Purpose

After the four user-facing phases are complete and validated, the codebase should consolidate the shared digest architecture that was intentionally allowed to remain duplicated during incremental delivery.

This phase is about reducing drift risk, not changing product scope.

### Goals

- unify repeated single-entry share / export sheet logic where the intended behavior already matches
- converge digest-hosted summary behavior more explicitly with the Reader summary feature contract
- establish one reusable settings-navigation path for feature UIs that need to open App Settings at a specific tab
- prepare the codebase for future digest-related sheets without copying the same glue code again

### Expected refactor targets

- extract a shared single-entry digest projection loader
- extract a shared note-draft controller for digest sheets
- extract shared digest template-binding and render-preparation helpers
- evaluate whether share / export sheets should compose from smaller shared sections rather than duplicating layout wiring
- unify "open settings at target tab" flows under shared `AppSettingsNavigation`-style helpers

### Non-goals

- no product-behavior change unless required to preserve existing contracts
- no redesign of note or summary semantics
- no large inheritance hierarchy for digest sheet view models

Preferred implementation style:

- use small composition helpers or controllers
- keep feature-specific UI layout differences allowed
- move repeated state and orchestration code into shared helpers

---

## App Settings

### Digest tab

App Settings must gain a top-level `Digest` tab before Phase 3 is considered complete.

Minimum initial settings:

- `Local Export Path`

Expected near-future occupants of the same tab:

- template override controls
- reset-to-default-template actions
- future digest format preferences if needed

This tab should exist even before all future controls are implemented, so the information architecture is stable from the first Markdown export release.

---

## Testing and Validation Strategy

Each phase must be closed with both automated and manual validation.

### Automated coverage

At minimum, each phase should add tests for:

- persistence rules
- rendering rules
- empty / missing optional-content cases
- phase-specific edge cases

### Manual validation

Each phase closeout should document a short operator checklist, for example:

- open the relevant UI
- create or modify data
- confirm preview
- confirm delivery result
- reopen and verify persisted state

---

## Open Decisions

The following decisions remain intentionally open and should be resolved before implementation advances too far:

1. Exact localized wording and punctuation details for built-in labels and summary attribution copy

These items should be treated as product-design decisions, not minor implementation details.

---

## Current Implementation Priority

The current design priority order is:

1. update and stabilize this document
2. finalize remaining wording details
3. implement Phase 1
4. implement Phase 2
5. add Digest settings tab
6. implement Phase 3
7. implement Phase 4
8. implement Phase 5
