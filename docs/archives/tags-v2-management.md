# Tags v2 Management Design

Status:
- Implemented.
- Covers delivered Phase 5.2 "Tag Library" management in Settings.
- This document now serves as the implementation contract and design rationale for the shipped management surface.

Purpose:
- Define the dedicated Tag Library management surface that complements, rather than duplicates, the lightweight tag actions already available in the main sidebar.
- Keep common tag actions simple in the main app, while making lower-frequency but necessary maintenance operations possible in one focused place.

Principle:
- Common things simple, uncommon things possible.

---

## 1. Product Positioning

The main sidebar `Tags` mode already supports day-to-day operations:
- browse tags,
- filter entries by tags,
- rename a tag,
- delete a tag.

The Settings-based Tag Library should therefore not become a second copy of the sidebar.

Its role is different:
- canonicalize the tag system,
- clean up long-tail tag drift,
- expose lower-frequency maintenance tools that are too heavy for a row context menu,
- keep advanced operations out of the main reading and filtering flow.

In short:
- sidebar = use tags,
- Tag Library = maintain the tag library.

---

## 2. Scope

Required for this phase:
- searchable Tag Library browser,
- alias management,
- explicit tag merge,
- provisional-tag management,
- delete-unused flow,
- single-tag delete from the management surface,
- high-precision potential-duplicates inspection.

Explicitly out of scope:
- hierarchical tags,
- tag colors/icons/notes,
- import/export tooling,
- bulk regex rename,
- semantic clustering,
- related-entries preview as a first-class panel area.

Note on related entries:
- This is intentionally omitted for now.
- The main app already supports filtering by tag, which is a better full-context surface for exploring tagged articles.
- The management UI should remain compact and maintenance-focused.

---

## 3. Entry Point and Window Model

Entry point:
- `General > Tag System > Tag Library...`

Window model:
- Open a dedicated sheet from Settings, similar in weight to Batch Tagging.
- Do not embed the full management UI inside the existing `General` form.

Rationale:
- The feature is too large and stateful for a simple inline settings subsection.
- A sheet preserves a focused maintenance workflow without polluting the primary app layout.

Recommended title:
- `Tag Library`

Recommended size:
- desktop-first, medium-to-large utility sheet.
- wide enough to support a list + inspector layout without crowding.

---

## 4. UX Shape

## 4.1 Overall Layout

Recommended layout:
- top toolbar,
- left library list,
- right inspector.

This should feel like a compact management workspace, not a spreadsheet and not a wizard.

Toolbar content:
- search field,
- small filter control,
- summary text (`N tags`, `M provisional`, `K unused`),
- one high-signal bulk action only when applicable: `Delete Unused...`.

Left pane:
- the tag library list.

Right pane:
- inspector for the selected tag.

Default empty state:
- if no tag is selected, show a short explanation of what this screen is for and how to use it.

## 4.2 Left Pane: Tag List

Each row should expose only information that helps maintenance decisions:
- tag name,
- usage count,
- provisional badge when applicable,
- alias count when non-zero.

Default sorting:
- `usageCount DESC`,
- then `name ASC`.

Search should match:
- canonical tag name,
- normalized name,
- alias text.

Filters should stay intentionally small:
- `All`
- `Provisional`
- `Unused`
- `Has Aliases`
- `Potential Duplicates`

These filters cover the main maintenance jobs without turning the UI into an admin console.

## 4.3 Right Pane: Inspector

The inspector is the advanced surface.

It should contain these sections:

1. `Identity`
- canonical name,
- normalized name (read-only),
- provisional / permanent state,
- usage count.

2. `Aliases`
- alias list,
- `Add Alias...`,
- per-alias delete.

3. `Potential Duplicates`
- only shown when high-confidence candidates exist,
- lists suggested nearby tags and the reason they were surfaced,
- offers maintenance actions such as `Merge Into...` or `Add as Alias...` where appropriate.

4. `Actions`
- `Rename...`
- `Merge Into...`
- `Make Permanent`
- `Delete Tag...`

Inspector principle:
- advanced actions are selection-driven.
- no global destructive controls without a clear selected target, except `Delete Unused...`.

---

## 5. Required Capabilities

## 5.1 Searchable Tag Library Browser

Purpose:
- provide one centralized place to inspect the full library, including provisional and low-usage tags.

Requirements:
- live search,
- small fixed filter set,
- stable sort,
- no pagination in v1 unless performance proves necessary.

## 5.2 Explicit Merge

This is the most important missing maintenance feature.

User flow:
1. Select a source tag.
2. Trigger `Merge Into...`.
3. Choose a target tag from a searchable picker.
4. Review a confirmation summary.
5. Confirm merge.

Confirmation summary should include:
- source tag name,
- target tag name,
- source usage count,
- target usage count,
- whether the source canonical name will be preserved as an alias,
- whether alias collisions will be skipped or rejected.

Merge semantics:
- move all `entry_tag` rows from source to target,
- use conflict-safe insert behavior so entries already tagged with both do not duplicate,
- preserve the source canonical name as an alias of the target,
- migrate source aliases onto the target where safe,
- delete the source tag,
- recalculate usage counts from actual assignments.

This operation belongs in Tag Library, not in the sidebar context menu.

## 5.3 Alias Management

Alias management should be first-class in this screen.

User actions:
- add alias to selected canonical tag,
- delete alias from selected canonical tag.

Validation rules:
- alias must be non-empty after trimming,
- alias normalized form must not collide with another canonical tag,
- alias normalized form must not collide with another alias,
- alias must not be equivalent to the selected canonical name.

Why this matters:
- many maintenance cases are not true merges; they are naming variants.
- alias management prevents unnecessary tag proliferation without forcing destructive consolidation.

## 5.4 Provisional Management

The library must make provisional tags visible and manageable.

Required capabilities:
- filter all provisional tags,
- inspect them the same way as normal tags,
- allow `Make Permanent` for a selected provisional tag.

Not required in this phase:
- forced demotion of permanent tags back to provisional.

Rationale:
- promotion is a clear user intention,
- demotion is harder to reason about and can be deferred.

## 5.5 Delete Unused

This should exist as a global maintenance tool, but with a narrow scope.

Definition:
- unused = `usageCount == 0`

Flow:
1. User triggers `Delete Unused...`.
2. Confirmation dialog summarizes the number of affected tags.
3. Confirm deletion.

Behavior:
- delete unused tags,
- delete their aliases,
- keep the operation atomic.

This is intentionally safer and more understandable than broader bulk delete tools.

## 5.6 Single-Tag Delete

Single-tag delete remains necessary in this screen because:
- maintenance often begins in the inspector,
- the user may arrive here from `Tag Library...` specifically to clean the library.

Behavior should match the existing sidebar delete semantics:
- delete the tag,
- remove its aliases,
- remove all associated `entry_tag` rows.

## 5.7 Potential Duplicates

This is a practical maintenance aid and should appear in the inspector for the selected tag.

Important positioning:
- this is suggestion-only,
- never automatic,
- never blocking,
- optimized for precision over recall.

Because strict normalized-name uniqueness already catches exact separator/case variants at write time, this view should only target cases not already prevented by the core model.

Initial high-precision heuristics should stay conservative. Good first candidates:
- singular/plural variants of the same normalized token sequence,
- very small edit distance on sufficiently long single-token tags,
- obvious orthographic near-duplicates that survived normalization and alias resolution.

Each surfaced candidate should include a reason label such as:
- `Pluralization variant`
- `Near spelling variant`
- `Likely naming variant`

Recommended actions from a duplicate candidate row:
- `Merge Into...`
- `Add as Alias...`

Do not add broad semantic matching in this phase.

---

## 6. Interaction Rules and Safety

## 6.1 Batch Tagging Interaction

While batch tagging is lifecycle-active:
- the Tag Library may still open,
- browsing, searching, and inspection remain available,
- mutating actions must be disabled.

Disabled during active batch lifecycle:
- rename,
- merge,
- add alias,
- delete alias,
- make permanent,
- delete tag,
- delete unused.

Rationale:
- this matches the existing destructive-mutation guard,
- avoids hidden cross-surface interference while staging/apply flows are active.

## 6.2 Confirmation Design

Only operations with meaningful destructive or canonical effects require confirmation:
- merge,
- delete tag,
- delete unused.

Alias add/remove and `Make Permanent` should not use heavyweight confirmation.

Confirmation text should be operation-specific and summary-based, not generic.

## 6.3 Surface Discipline

This screen should own its own status and error presentation.

Use:
- inline fixed message area near the toolbar or inspector for recoverable issues,
- confirmation dialogs for destructive actions.

Do not:
- project Tag Library maintenance notices into Reader banner,
- reuse unrelated task host message surfaces.

---

## 7. Implementation Architecture

## 7.1 Keep Responsibilities Separate

Current split:
- sidebar and reader tagging flows are entry-centric,
- Tag Library is library-centric.

That separation should remain visible in code.

Recommended structure:
- keep `EntryStore` focused on entry-scoped tagging and existing lightweight tag mutations,
- introduce a dedicated `TagLibraryStore` for library-wide maintenance queries and mutations.

Why:
- merge, alias management, and bulk unused deletion are not entry concerns,
- this avoids turning `EntryStore` into a catch-all tag admin object,
- it reduces accidental coupling between reader flows and library maintenance.

Recommended files:
- `Mercury/Core/Database/TagLibraryStore.swift`
- `Mercury/App/Views/TagLibrarySheetView.swift`
- `Mercury/App/Views/TagLibraryViewModel.swift`
- `Mercury/Feed/AppModel+TagLibrary.swift`

## 7.2 Shared Mutation Guard

Do not duplicate the active-batch guard across multiple stores forever.

Recommended extraction:
- a small shared helper for tag-mutation policy, used by both existing lightweight mutations and the new Tag Library mutations.

Example responsibility:
- `TagMutationPolicy.assertNoActiveBatchLifecycle(db:)`

This keeps the guard centralized and reduces drift.

## 7.3 Read Models for the Management UI

Do not bind the Settings UI directly to raw database models where richer aggregated information is required.

Recommended read models:
- `TagLibraryListItem`
  - `tagId`
  - `name`
  - `normalizedName`
  - `isProvisional`
  - `usageCount`
  - `aliasCount`
  - `hasPotentialDuplicates`
- `TagLibraryInspectorSnapshot`
  - canonical tag identity,
  - aliases,
  - usage info,
  - action availability,
  - potential duplicate candidates.
- `TagDuplicateCandidate`
  - `tagId`
  - `name`
  - `usageCount`
  - `reason`

This keeps UI computation out of SwiftUI views and limits churn when the underlying schema evolves.

## 7.4 Mutation API Design

Recommended `TagLibraryStore` write APIs:
- `renameTag(id:newName:)`
- `mergeTag(sourceID:targetID:)`
- `addAlias(tagId:alias:)`
- `deleteAlias(id:)`
- `makeTagPermanent(id:)`
- `deleteTag(id:)`
- `deleteUnusedTags()`

The existing sidebar rename/delete flows may continue using current `AppModel` entry points initially, but both surfaces should converge on the same underlying mutation semantics.

Preferred direction:
- the `AppModel` methods become the stable UI-facing surface,
- those methods delegate to the correct underlying store,
- UI code does not know about SQL or migration details.

## 7.5 Merge Contract Details

`mergeTag(sourceID:targetID:)` should be atomic.

Contract:
- reject `sourceID == targetID`,
- reject missing source or target,
- reject when batch lifecycle is active,
- migrate `entry_tag` associations safely,
- migrate aliases safely,
- preserve source canonical name as alias of target when valid,
- delete source,
- recalculate affected usage counts from `entry_tag`,
- avoid leaving partially migrated state if any step fails.

This contract should be documented in code and tested directly.

## 7.6 Potential Duplicate Service

Do not bake potential-duplicate heuristics into write paths.

Recommended structure:
- a pure helper or dedicated read-only service,
- called lazily when inspector selection changes,
- returns candidates only for presentation.

Important:
- duplicate suggestions must never affect assignment, alias resolution, or tag creation automatically.
- this feature is advisory only.

## 7.7 View Model Boundaries

The sheet should use a dedicated view model.

`TagLibraryViewModel` responsibilities:
- search text,
- selected filter,
- selected tag id,
- list loading,
- inspector loading,
- action enable/disable state,
- local status message,
- confirmation state for merge/delete/bulk delete.

It should not:
- own database logic,
- compute duplicate heuristics directly,
- perform ad-hoc SQL.

---

## 8. Interaction with Existing Features

## 8.1 Sidebar Tags Mode

The sidebar remains the lightweight operational surface.

No goal in this phase:
- do not move everyday rename/delete out of the sidebar,
- do not add merge or alias editing into sidebar row menus,
- do not overload the sidebar with maintenance-only affordances.

The two surfaces should share mutations, not share UI responsibilities.

## 8.2 Reader Tagging Panel

The reader tagging panel should remain unaffected by Tag Library as a UI concept.

Indirect effects are acceptable and desirable:
- alias additions improve future matching,
- merges reduce duplicate suggestions,
- permanent promotion improves vocabulary quality.

Direct coupling is not acceptable:
- no Tag Library UI state should leak into the reader,
- no reader view should depend on the Tag Library sheet being open.

## 8.3 Batch Tagging

Batch tagging interacts with the library at the data-contract level, not the UI level.

Requirements:
- destructive/canonical mutations are blocked while batch lifecycle is active,
- read-only browsing remains allowed,
- batch review/apply logic must not depend on Tag Library UI state.

This keeps the system stable even when both features exist in the same Settings area.

---

## 9. Localization and Messaging

All user-visible strings must be localized through the standard bundle-aware APIs.

The management screen will introduce a new cluster of strings:
- filters,
- inspector headings,
- action labels,
- duplicate reason labels,
- confirmation summaries,
- inline validation and status messages.

Do not hard-code maintenance-only strings in view models or stores.

If a validation error is truly internal or diagnostic-only, keep it out of localization and out of the user surface.

---

## 10. Testing Expectations

The implementation should include direct store-level coverage for:
- merge semantics,
- alias collision validation,
- alias add/delete,
- make permanent,
- delete unused,
- delete single tag,
- active-batch mutation blocking.

Potential duplicate heuristics should have deterministic tests for:
- positive high-confidence examples,
- negative examples that must not be surfaced.

UI-facing tests or smoke tests should cover:
- search + filter behavior,
- inspector refresh when selection changes,
- action disabled state during active batch lifecycle,
- merge/delete confirmation flows.

---

## 11. Recommended Phase 5.2 Deliverable

The phase is complete when:
- `Tag Library...` opens a real management sheet,
- the sheet supports search, filter, selection, and inspector,
- merge is implemented,
- alias management is implemented,
- provisional management is implemented,
- delete-unused is implemented,
- potential duplicates are surfaced conservatively in the inspector,
- all mutating actions are blocked during active batch lifecycle,
- existing sidebar behavior remains intact and uncomplicated.

This yields a maintenance surface that is stronger than the sidebar, but still small, focused, and coherent.

---

## 12. Implementation Plan

This phase should be implemented in a sequence that preserves existing tag flows and minimizes cross-feature churn.

## 12.1 Stage 1 - Shared Contracts and Store Boundary

Goal:
- establish the data-layer foundation before any UI work.

Tasks:
- add a dedicated `TagLibraryStore` under `Mercury/Core/Database/`.
- move library-wide maintenance queries and mutations into this store instead of expanding `EntryStore`.
- extract a shared tag-mutation guard helper so sidebar mutations and Tag Library mutations use the same active-batch policy.
- define read models for the management UI:
  - `TagLibraryListItem`
  - `TagLibraryInspectorSnapshot`
  - `TagDuplicateCandidate`
- define mutation contracts for:
  - `mergeTag(sourceID:targetID:)`
  - `addAlias(tagId:alias:)`
  - `deleteAlias(id:)`
  - `makeTagPermanent(id:)`
  - `deleteUnusedTags()`

Acceptance criteria:
- no Settings UI yet,
- the store compiles and exposes a coherent API,
- no existing sidebar or reader code path needs to know SQL details of Phase 5.2.

## 12.2 Stage 2 - Core Mutation Implementation

Goal:
- implement the actual tag-library mutations with strong transactional guarantees.

Tasks:
- implement `mergeTag(sourceID:targetID:)` as one atomic write transaction.
- implement alias add/delete with collision validation.
- implement `makeTagPermanent(id:)`.
- implement `deleteUnusedTags()` as one atomic operation.
- keep single-tag delete behavior semantically aligned with the existing sidebar delete flow.
- centralize usage-count recomputation logic for merge/delete operations if needed, instead of re-implementing local counting in multiple methods.

Important design constraint:
- no mutation in this stage should depend on Tag Library UI state or view model state.

Acceptance criteria:
- merge preserves canonicalization semantics,
- alias validation is deterministic,
- active batch lifecycle blocks all destructive/canonical mutations,
- existing reader and sidebar flows are unchanged.

## 12.3 Stage 3 - Potential Duplicate Detection

Goal:
- add a conservative read-only duplicate suggestion facility.

Tasks:
- implement a pure or read-only helper that surfaces high-confidence duplicate candidates for a selected tag.
- scope heuristics to the conservative set defined earlier:
  - singular/plural variants,
  - very small edit distance on sufficiently long names,
  - obvious orthographic near-duplicates not already absorbed by normalization or aliasing.
- emit reason labels with each candidate.
- integrate this logic only into inspector data loading, not any write path.

Non-goals:
- no background maintenance queue,
- no automatic duplicate resolution,
- no write-time semantic blocking.

Acceptance criteria:
- duplicate suggestions are advisory only,
- false positives remain low on deterministic tests,
- no effect on assignment, alias resolution, or tag creation behavior.

## 12.4 Stage 4 - AppModel Surface

Goal:
- define a stable app-facing interface before building the management sheet.

Tasks:
- add `AppModel+TagLibrary.swift`.
- expose async methods for:
  - loading list items,
  - loading inspector snapshot,
  - merge,
  - alias add/delete,
  - make permanent,
  - delete tag,
  - delete unused.
- reuse the same app-facing error/reporting conventions already used elsewhere in Mercury where appropriate.
- ensure mutation completion increments `tagMutationVersion` so existing reader/sidebar observers continue to refresh correctly.

Acceptance criteria:
- Tag Library UI can depend only on `AppModel` methods,
- existing UI refresh behavior remains correct after tag-library mutations,
- no direct store references are needed from SwiftUI views.

## 12.5 Stage 5 - Tag Library Sheet and View Model

Goal:
- implement the management UI as an isolated Settings-hosted workflow.

Tasks:
- add `TagLibrarySheetView.swift`.
- add `TagLibraryViewModel.swift`.
- implement:
  - toolbar search,
  - fixed filter set,
  - tag list,
  - empty state,
  - inspector sections,
  - confirmation flows for merge/delete/delete-unused,
  - inline local status/error area.
- ensure the sheet behaves well with no selection, empty search result, and disabled mutation states during active batch lifecycle.

Design constraint:
- the sheet should remain compact and maintenance-focused, not become a generic database admin tool.

Acceptance criteria:
- the full required Phase 5.2 interaction model is usable from the sheet,
- the inspector is the only place where advanced operations live,
- browsing remains available when mutations are disabled.

## 12.6 Stage 6 - Settings Integration

Goal:
- wire the existing `Tag Library...` placeholder button to the real feature.

Tasks:
- add presentation state in `GeneralSettingsView`.
- open the dedicated Tag Library sheet from the existing `Tag Library...` button.
- keep the `General > Tag System` section otherwise unchanged.

Acceptance criteria:
- Settings remains simple,
- `Tag Library...` opens the management sheet,
- no unrelated Settings layout churn is introduced.

## 12.7 Stage 7 - Localization

Goal:
- localize the entire management surface cleanly before considering the phase complete.

Tasks:
- add all user-visible strings for:
  - filters,
  - inspector section titles,
  - action labels,
  - duplicate reason labels,
  - confirmation copy,
  - validation and status messages.
- keep internal diagnostics and debug-only strings out of localization.
- prefer shared wording if an existing semantic already exists elsewhere in the app.

Acceptance criteria:
- no important Tag Library user-facing strings are left outside the localization system,
- zh-Hans coverage is complete for the new management UI.

## 12.8 Stage 8 - Tests

Goal:
- add coverage where the new phase changes core contracts.

Store-level tests:
- merge success path,
- merge conflict-safe behavior when entries already contain both tags,
- alias add success,
- alias collision rejection,
- alias delete,
- make permanent,
- delete unused,
- active batch lifecycle blocking.

Duplicate detection tests:
- positive cases for each heuristic,
- negative cases that must not surface.

UI / integration smoke tests:
- search and filter update the list correctly,
- inspector refreshes when selection changes,
- destructive actions require confirmation,
- mutation actions disable correctly during active batch lifecycle,
- `tagMutationVersion` propagation still refreshes existing tag consumers.

Acceptance criteria:
- the new maintenance contracts are verified directly,
- existing tag features are not regressed by the management layer.

## 12.9 Suggested Landing Order

Recommended landing sequence:
1. shared mutation guard + `TagLibraryStore` contracts,
2. merge / alias / permanent / delete-unused implementation,
3. duplicate detection helper,
4. `AppModel+TagLibrary` surface,
5. Tag Library sheet + view model,
6. Settings wiring,
7. localization pass,
8. final test and regression pass.

This order keeps the architecture clean:
- data semantics first,
- UI later,
- wiring last.
