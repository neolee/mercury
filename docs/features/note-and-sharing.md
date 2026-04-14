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

## Phase 5: Digest Template Customization and Shared Template Loading

### Purpose

After the four user-facing phases are complete and validated, the next iteration should finish the digest customization architecture instead of only polishing internal duplication.

This phase has two tightly coupled deliverables:

1. user-customizable digest templates
2. consolidation of shared digest template loading / override / fallback behavior

This phase still does not expand digest product scope beyond share / export. It focuses on making the existing digest output pipeline customizable, explainable, and safe to evolve.

### Product outcome

At the end of this phase, Mercury should support three digest template customization entry points that behave consistently with agent prompt customization:

- Share Digest template
- Export Digest template
- Export Multiple Digest template

Each entry point should let the user reveal a sandbox copy of the corresponding YAML template, edit it externally, and have Mercury automatically prefer the customized file when it is valid.

### Hard alignment with agent template customization

Digest template customization should intentionally mirror the agent prompt customization workflow wherever possible.

Required behavior:

- built-in digest templates remain the source of truth and the default fallback
- user customization uses a sandbox file copied from the built-in template on first use
- runtime loading prefers the user-customized file when present and valid
- if the user-customized file is invalid, Mercury must preserve the file on disk, log a debug issue, fall back to the built-in template, and show a lightweight user-facing notice
- the customization entry point should reveal the concrete template file in Finder rather than introducing an in-app YAML editor
- deleting the sandbox file should restore built-in behavior automatically

Implementation constraint:

- the digest flow should reuse the same override / fallback design as `AgentPromptCustomization`
- when logic is structurally identical, it should be extracted into shared helpers rather than copied into digest-specific code

### Scope

This phase includes:

- shared digest template customization config and file-location rules
- per-template override discovery for all three digest outputs
- fallback and invalid-template notice behavior in digest sheets
- shared digest template loading and render-preparation helpers
- Digest settings controls for template customization

This phase does not include:

- an in-app template editor
- arbitrary user-defined new digest template types
- per-entry template selection inside share / export sheets
- digest-specific scripting or computed template logic beyond the existing placeholder / section model

### Required architecture

Digest template customization should converge on one shared customization layer analogous to the existing agent prompt customization stack.

Expected pieces:

- one shared `TemplateCustomization` module for file-copy, override discovery, fallback loading, reveal-in-Finder, reset-by-deletion, and localized invalid-template fallback notice plumbing
- a digest-template customization config describing file name, built-in template name, template id, invalid-template debug title, and localized fallback message
- one shared customization loader that resolves built-in versus customized files
- one shared "ensure sandbox file exists and reveal it" helper for settings actions
- one shared load path used by all digest sheets instead of each sheet loading built-in templates directly

The target outcome is:

- `ReaderShareDigestSheetViewModel`
- `ReaderExportDigestSheetViewModel`
- `ExportMultipleDigestSheetViewModel`

should all delegate template resolution to the same shared digest customization path.

Type-level note:

- `AgentPromptTemplate` and `DigestTemplate` remain separate types with separate schema/validation contracts
- the shared extraction target is the customization workflow and fallback plumbing, not a merged template model
- `AgentPromptCustomization` should be reduced to an agent-specific facade over the shared customization module where practical

### UI and notice behavior

Digest sheets already have lightweight information surfaces and should reuse them instead of inventing a second notification system.

Required behavior when a customized digest template is invalid:

- log a debug issue with the file path, validation error, and fallback action
- continue rendering using the built-in template
- surface a lightweight notice in the active share / export sheet using its existing informational UI pattern
- do not block copy / share / export if built-in fallback succeeds
- report the invalid-custom-template debug issue at most once per sheet session for the same template file / fallback event

The notice text should clearly communicate only the necessary facts:

- the customized digest template is invalid
- Mercury is temporarily using the built-in template

This wording should follow the same product tone as agent invalid-template fallback messaging.

Placement rule:

- all three digest sheets should use the action-row leading message area as the shared surface for lightweight digest-template fallback notices
- when both an operational error and an informational fallback notice are available, the operational error takes precedence
- no separate banner, modal, or template-specific notification chrome should be introduced for this phase

### Digest settings requirements

The `Digest` settings tab should become the stable home for digest template customization, not just export-path configuration.

Required controls for this phase:

- keep the existing `Local Export Path` section
- add one template-customization section below it
- include one row for `Share Digest`, one for `Export Digest`, and one for `Export Multiple Digest`
- each row exposes a highlighted clickable text action labeled `custom template`
- the action behavior should match the existing agent prompt customization flow: ensure the sandbox copy exists, then reveal it in Finder
- resetting to built-in behavior remains file-deletion based; this phase does not require a separate in-app reset button

Settings copy should explain that:

- Mercury ships with built-in templates
- the first customization action creates a personal copy
- invalid custom templates automatically fall back to the built-in version
- deleting the customized file restores the built-in template automatically

### Shared loading and deduplication plan

This phase replaces the previous open-ended consolidation goal with a narrower, implementation-driven target: remove template-loading drift first.

Mandatory refactor targets:

- extract shared digest template customization config and fallback messaging
- extract shared template load / fallback / invalid-report logic
- extract shared digest render-preparation helpers where share / export sheets currently repeat the same load-or-report structure
- keep existing shared projection loading, note draft control, and settings navigation in place and extend them only when needed

Explicitly not required for this phase:

- merging single-entry share / export sheet view models into one type
- redesigning summary generation UI
- redesigning note editing UI

Preferred implementation style:

- use small shared helpers and configs
- keep per-sheet layout and output-specific logic separate
- deduplicate loading, fallback, and reporting behavior before deduplicating unrelated UI structure

### File and storage direction

Digest customization files should live in the user sandbox with a predictable structure parallel to agent prompt customization.

Recommended direction:

- keep built-in templates in `Resources/Digest/Templates/`
- create user copies under an Application Support subtree dedicated to digest templates
- use one stable file per built-in digest template

Expected customized file set:

- `single-text.yaml`
- `single-markdown.yaml`
- `multiple-markdown.yaml`

### Validation requirements

Automated coverage added or updated in this phase should include:

- customized digest template is preferred when valid
- invalid customized digest template falls back to built-in
- invalid customized digest template preserves copy / share / export availability when built-in fallback succeeds
- reveal action creates sandbox copy only once and never overwrites user changes
- reset-to-built-in removes the sandbox override and restores built-in output
- all three digest sheet paths use the shared customization loader rather than ad-hoc built-in loading

Manual validation should include:

- reveal each digest template from Settings > Digest
- edit one template, reopen the matching digest sheet, and confirm the preview reflects the customized template
- introduce a template syntax error and confirm fallback notice plus working output
- delete or reset the customized file and confirm built-in output returns

Clarification:

- "preview stays in sync" during an open digest sheet refers to digest content changes already managed inside the sheet, such as note edits, summary generation, and other in-sheet controls
- this phase does not require live hot-reload of a template file that is edited externally while the same digest sheet is already open

### Non-goals

- no new digest output modes
- no in-app template authoring UI
- no expansion of the placeholder language beyond the approved baseline syntax
- no large inheritance hierarchy for digest sheet view models

---

## Custom Guide

### User guide deliverable

After digest template customization is implemented, Mercury should add a standalone user-facing customization guide:

- `CUSTOM.md`

`README.md` should link to this guide instead of trying to inline all customization details.

This guide should cover both:

- agent prompt customization
- digest template customization

### Guide goals

The guide should optimize for practical success, not only API completeness.

It should help users answer:

- where customized files live
- how to create and reveal them
- how fallback works when a template is invalid
- which parts of a template are structurally coupled and should usually be edited together
- what are safe first edits for beginners

### Digest-specific guidance requirements

The guide must explicitly explain that some placeholder and section combinations are structural contracts rather than independent cosmetic fragments.

Example that must be documented:

```text
{{#includeSummary}}
> {{summaryTextBlockquote}}
{{/includeSummary}}
```

The guide should explain:

- `includeSummary` controls whether the whole summary block exists
- `summaryTextBlockquote` is the formatted summary payload expected inside that block
- users usually customize the surrounding Markdown styling of the block, not the existence contract itself
- removing or misclassifying section wrappers can change feature behavior, not just appearance

The same style of explanation should be given for:

- note sections
- repeated `entries` sections in multiple-entry export
- front matter placeholders such as `digestTitle` and `fileSlug`

### Guide examples

The guide should include small, practical examples such as:

- changing the note label wording
- changing summary presentation from blockquote to a titled section while preserving the summary section wrapper
- adding a stable front matter field to Markdown exports
- lightly reformatting each entry in multiple-entry export without breaking the repeated `entries` section

The guide should also include one or two explicit anti-examples showing edits that look harmless but would break template contracts.

---

## App Settings

### Digest tab

App Settings must gain a top-level `Digest` tab before Phase 3 is considered complete.

Minimum initial settings:

- `Local Export Path`

Expected near-future occupants of the same tab:

- per-template reveal / open customization actions
- reset-to-default-template actions
- fallback behavior explanation for invalid customized templates
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

## Wording Decisions

The built-in digest wording is now fixed for implementation and validation:

- note label: `My Take`
- source label: `Source`
- author label: `Author`
- summary attribution prefix / suffix: `Generated by` ... `in`

If wording changes are needed later, they should be treated as an explicit product copy revision rather than an implementation placeholder.

These items should be treated as product-design decisions, not minor implementation details.

---

## Current Implementation Priority

The current design priority order is:

1. update and stabilize this document
2. implement Phases 1-4 and validate them
3. implement Phase 5 shared digest template customization and loading consolidation
4. add `CUSTOM.md` and link it from `README.md`
5. refine wording and examples after the customization workflow is verified in product
