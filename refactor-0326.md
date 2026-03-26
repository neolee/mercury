# Refactor 0326

This memo captures the planned refactor around URL HTTPS upgrade handling, reader URL persistence, and `Feed` / `Reader` code ownership cleanup.

## Scope

This refactor covers four related goals:

1. Reader should upgrade persisted `http` article URLs to `https` when possible, use the upgraded URL immediately, and persist the upgraded URL back to the entry record.
2. All app-authored `http -> https` URL rewriting should flow through one shared helper so that a future policy change such as "probe reachability before replacing" can be implemented in one place.
3. `Feed` and `Reader` directory ownership should be made explicit and reflected in file placement.
4. `UseCase` should remain a `Feed`-local organization concept only. Code moved out of `Feed` must not keep `UseCase` naming or placement.

This memo does not implement network reachability probing yet. It prepares the codebase so that such a change can be introduced later in a controlled way.

## Current Findings

### URL upgrade logic is duplicated

There are currently multiple independent `http -> https` rewrite sites:

- `Feed/SyncService.swift`
  - Entry URL normalization and upgrade during feed sync
- `Feed/FeedTitleResolver.swift`
  - `siteURL` candidate upgrade before trying fetches
- `Feed/ReaderFetchRedirectPolicy.swift`
  - Reader redirect upgrade for same-host insecure redirects

These copies are similar but not identical. That makes future policy changes harder to audit and test.

### Reader pipeline code is living under `Feed`

The following files are reader-pipeline code by responsibility, but are currently placed under `Feed`:

- `Feed/UseCases/ReaderBuildUseCase.swift`
- `Feed/ReaderFetchRedirectPolicy.swift`

This is a directory-boundary mismatch. These files are not about feed ingestion or feed management. They are about transforming an `Entry` URL into readable content.

### `LocalTaggingService` is also misplaced

`Feed/UseCases/LocalTaggingService.swift` is currently only a local NLP tagging helper. It is not feed-specific and should not live under `Feed`.

A better home is `Core/Tags/`.

### `UseCase` is only a `Feed`-side convention today

Only `Feed` currently uses the `UseCase` naming and folder convention. Other subsystems do not. Keeping that pattern inside `Feed` is fine for now, but it should not spread by accident into other domains.

## Target Ownership Boundaries

### `Feed/`

`Feed` owns:

- feed CRUD
- feed validation
- OPML import/export
- bootstrap
- feed synchronization
- feed-to-entry metadata mapping
- initial entry URL normalization during sync
- entry list, sidebar, and feed-scoped read-state behaviors

`Feed` does not own:

- article body fetching for reader mode
- readability extraction
- reader rebuild policy
- reader redirect handling
- reader render cache orchestration

### `Reader/`

`Reader` owns:

- article fetch from `entry.url`
- reader-specific redirect handling
- readability extraction
- cleaned HTML / Markdown / rendered HTML pipeline
- reader rebuild policy and cache invalidation
- reader-specific persistence decisions tied to article loading

### `Core/Shared/`

`Core/Shared` owns:

- cross-domain URL normalization helpers
- shared pure helper logic that is not feed-only and not reader-only

### `Core/Tags/`

`Core/Tags` owns:

- tag normalization
- tag suggestion primitives
- local NLP tag extraction helpers

## Naming and Organization Rule

`UseCase` remains a `Feed`-local organizational concept only.

Rules:

- Files moved out of `Feed` must not keep `UseCase` naming.
- Types moved out of `Feed` must not keep `UseCase` in type names.
- Functions, properties, and local symbols introduced to support moved code should not keep `UseCase` naming once that code belongs to `Reader`, `Core`, or other non-`Feed` domains.
- New reader-domain files should use straightforward names such as `ReaderBuildPipeline`, `ReaderContentLoader`, or `ReaderFetchRedirectPolicy`.
- Shared infrastructure should use neutral names in `Core/Shared` rather than domain-specific names that imply `Feed` ownership.

For this refactor, the practical implication is:

- `ReaderBuildUseCase.swift` should not be moved as-is to `Reader/UseCases/...`
- it should be renamed to a normal reader-domain file name when moved
- its exported symbols and dependent property names should also be renamed to match the new ownership

Recommended rename:

- `Feed/UseCases/ReaderBuildUseCase.swift`
- to `Reader/ReaderBuildPipeline.swift`

Recommended symbol rename:

- `ReaderBuildUseCase`
- to `ReaderBuildPipeline`

Recommended dependent rename:

- `readerBuildUseCase`
- to `readerBuildPipeline`

This keeps the file aligned with the existing reader pipeline vocabulary:

- `ReaderRebuildPolicy`
- `ReaderPipelineVersion`
- `ReaderPipelineInvalidationTarget`

## Proposed Shared URL Helper

Add one shared Foundation-only helper under `Core/Shared/`.

Recommended file:

- `Core/Shared/URLHTTPSUpgrade.swift`

Recommended public surface:

- `URLHTTPSUpgrade.preferredHTTPSURL(from: URL) -> URL`
- `URLHTTPSUpgrade.preferredHTTPSURLString(from: String) -> String?`

Expected behavior for the helper:

- If scheme is `http`, rewrite to `https`
- Preserve host, path, query, and fragment
- Remove explicit port `80` when upgrading to `https`
- Leave `https` unchanged
- Return `nil` for malformed input in string-based APIs

This helper is intentionally pure and non-probing.

The future probing policy can then be added by changing a small number of call sites or by extending this helper layer without first hunting for duplicate rewrite logic across domains.

## Proposed File Moves

### Move and rename reader pipeline code

- Move `Feed/UseCases/ReaderBuildUseCase.swift`
- To `Reader/ReaderBuildPipeline.swift`

- Move `Feed/ReaderFetchRedirectPolicy.swift`
- To `Reader/ReaderFetchRedirectPolicy.swift`

### Move local tagging helper

- Move `Feed/UseCases/LocalTaggingService.swift`
- To `Core/Tags/LocalTaggingService.swift`

No behavior change is intended from the move itself. This is an ownership cleanup.

## Proposed Reader URL Persistence Behavior

Reader should perform best-effort persistence upgrade for stored article URLs.

Target behavior:

1. When reader starts from an `Entry` whose persisted `url` is `http`, compute the preferred `https` URL via the shared helper.
2. Use the upgraded `https` URL immediately for:
   - source HTML fetch
   - Readability `baseURL`
3. If the entry has an ID, attempt to persist the upgraded URL back to the entry row.
4. Persistence failure must not fail the reader build itself.

Rationale:

- The reader pipeline should use the strongest known URL immediately.
- Persistence should improve future runs.
- Reader functionality should not regress because of a write conflict.

## Database Write Path

Add a single entry-store mutation API instead of writing directly from reader code.

Recommended API in `Core/Database/EntryStore.swift`:

- `func updateURL(entryId: Int64, url: String) async throws`

Behavior:

- Update the row by `id`
- Update in-memory entry-list state only if that state later grows to include `url`
- Do not silently broaden its responsibility beyond URL mutation

This keeps reader code out of raw database update details.

## UI Consistency Note

`selectedEntryDetail` in `ContentView` is a value snapshot loaded from `EntryStore`.

That means:

- updating the database URL during reader load will not automatically update the currently displayed `Entry` value already held by the view layer

Recommended small follow-up in this refactor:

- after a reader build finishes for the currently selected entry, reload selected entry detail once

This is not required for correctness of content loading, but it keeps the current UI model consistent with the newly persisted `https` URL for actions such as opening the entry in the browser.

## Error Handling Policy

Reader URL persistence upgrade should be best-effort.

Possible failure cases:

- unique index conflict on `(feedId, url)`
- write failure due to unrelated database state

Required behavior:

- article fetch should proceed using the upgraded URL even if persistence fails
- persistence failure should not surface as a reader build failure
- optionally log a debug issue if the failure is useful for diagnosis

## Step-by-Step Implementation Plan

The implementation should be done in the following order.

### Step 1: Introduce the shared HTTPS upgrade helper

Changes:

- Add `Core/Shared/URLHTTPSUpgrade.swift`
- Add focused tests for the helper

Verification:

- helper tests cover:
  - `http -> https`
  - preserve path/query/fragment
  - remove `:80`
  - leave `https` unchanged

Acceptance criteria:

- there is exactly one canonical helper for app-authored scheme upgrades
- no new feature code introduces direct `URLComponents(...).scheme = "https"` logic outside this shared helper

### Step 2: Rewire existing upgrade sites to use the shared helper

Changes:

- Update `Feed/SyncService.swift`
- Update `Feed/FeedTitleResolver.swift`
- Update `Reader/ReaderFetchRedirectPolicy.swift` after move

Verification:

- repository search shows URL scheme upgrade logic only in the shared helper plus reader redirect policy conditions
- behavior remains unchanged for existing paths

Acceptance criteria:

- all app-authored `http -> https` rewrites call the shared helper
- reader redirect policy still owns only the decision rule, not the low-level rewrite logic

### Step 3: Move and rename reader pipeline files

Changes:

- Move `Feed/UseCases/ReaderBuildUseCase.swift` to `Reader/ReaderBuildPipeline.swift`
- Move `Feed/ReaderFetchRedirectPolicy.swift` to `Reader/ReaderFetchRedirectPolicy.swift`
- Update `AppModel` and all references

Verification:

- `Feed/` contains no `Reader*` files
- build passes without any path or symbol breakage

Acceptance criteria:

- reader pipeline code is physically located under `Reader/`
- moved reader code no longer uses `UseCase` naming
- moved reader symbols and dependent property/function names no longer use `UseCase` naming

### Step 4: Move `LocalTaggingService` out of `Feed`

Changes:

- Move `Feed/UseCases/LocalTaggingService.swift` to `Core/Tags/LocalTaggingService.swift`
- Update references from `AppModel` and reader tagging panel

Verification:

- `Feed/UseCases/` no longer contains `LocalTaggingService`
- build passes

Acceptance criteria:

- `LocalTaggingService` lives in `Core/Tags/`
- no behavior change in tagging suggestions

### Step 5: Add single-point entry URL persistence API

Changes:

- Add `EntryStore.updateURL(entryId:url:)`

Verification:

- a targeted test confirms entry URL can be updated by ID

Acceptance criteria:

- reader code no longer needs to manage direct entry-row URL updates

### Step 6: Upgrade persisted `http` entry URLs during reader load

Changes:

- In reader pipeline entry loading, detect persisted `http` `entry.url`
- compute preferred `https`
- use upgraded URL for fetch and Readability base URL
- attempt best-effort persistence via `EntryStore.updateURL`

Verification:

- test case for persisted `http` entry URL:
  - reader uses `https`
  - persisted URL is upgraded after successful path
- test case for persistence conflict:
  - reader still succeeds using upgraded URL

Acceptance criteria:

- reader no longer fails immediately just because the persisted article URL is still `http`
- upgraded URLs are persisted when possible

### Step 7: Refresh current selected entry detail after successful reader upgrade

Changes:

- After reader build for the selected entry, reload `selectedEntryDetail` once when a URL upgrade was applied

Verification:

- currently selected entry detail reflects the new `https` URL after reader load

Acceptance criteria:

- current view model state stays aligned with database state for the selected entry

### Step 8: Full verification and audit

Run:

- `./scripts/build`
- targeted tests for the new helper
- targeted tests for reader URL upgrade persistence
- targeted tests for reader redirect upgrade logic

Repository audit:

- search for app-authored `scheme = "https"` rewrites
- confirm only the shared helper performs low-level upgrade rewriting

Acceptance criteria:

- build succeeds
- targeted tests succeed
- search audit matches the intended architecture

## Verifiable Search Checklist

After implementation, the following checks should hold.

### Directory ownership

- `Feed/` contains no reader pipeline files
- `Feed/UseCases/` contains only feed-domain use cases
- `Reader/` contains reader pipeline code
- `Core/Tags/` contains `LocalTaggingService`

### Naming policy

- no moved non-feed file still uses `UseCase` in its filename
- no moved non-feed type still uses `UseCase` in its type name
- no dependent non-feed property or function name still uses `UseCase` due to the moved code

### URL helper centralization

Repository search for direct app-authored scheme rewrite code should only find:

- the shared helper
- reader redirect policy condition checks

Direct rewrites such as the following should not remain scattered:

- `components?.scheme = "https"`
- ad hoc `if url.scheme == "http"` upgrade blocks

## Non-Goals

This refactor does not yet introduce:

- HEAD/GET probing before URL replacement
- a broader network policy layer for all HTTP/HTTPS decisions
- changes to feed-level `https` validation policy

Those can be considered later, after the URL rewrite logic has been centralized.

## Recommended Review Order

When reviewing the eventual implementation, review in this order:

1. shared URL helper API and tests
2. file moves and renames
3. `EntryStore.updateURL`
4. reader persisted-URL upgrade behavior
5. UI refresh follow-up
6. repository-wide audit that no duplicate upgrade logic remains
