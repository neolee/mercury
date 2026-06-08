# Porting Mercury to Windows and Linux

This document captures the current high-level analysis and initial plan for bringing Mercury to Windows first, with Linux as a secondary target.

## Goals

- Keep the macOS version native and uncompromised.
- Prioritize Windows far above Linux.
- Reuse the non-UI code that carries real product value, especially `Readability` and database logic.
- Accept that Windows/Linux UI will likely be rewritten with a different framework and may not fully match the SwiftUI macOS experience.
- Keep cross-platform development cost under control by separating core reuse from platform-specific UI.
- Treat the first phase as a narrow feasibility gate, not as the start of a broad repository refactor.

## Current Judgment

A direct port of the existing SwiftUI/AppKit app is not realistic. Mercury currently depends on macOS-specific APIs across UI, WebView hosting, file panels, pasteboard, sharing, fonts, spelling, security-scoped bookmarks, App Intents, and other system integration.

The better target is:

1. macOS keeps the existing native SwiftUI app.
2. Windows gets a new UI shell.
3. Shared non-UI Swift modules provide the core behavior and storage.
4. Linux remains possible, but does not drive early architecture choices.

## Highest-Value Reuse Targets

### `Readability`

`Readability` should be treated as a strategic asset, not a replaceable dependency.

Reasons:

- It has accumulated long-term compatibility work against Mozilla Readability.
- It includes real-world fixture fixes and intentional quality improvements.
- Rewriting it in JavaScript, Rust, C#, or TypeScript would recreate a large amount of subtle behavior and test work.
- It is already designed as a standalone Swift package, making it the best first candidate for Windows validation.

Decision: preserve and reuse `Readability` if Windows Swift package builds and tests are viable.

### Database Layer

The database layer is the other critical reuse target.

This includes:

- schema definitions
- migrations
- GRDB models
- store/query APIs
- business invariants
- tests around feeds, entries, content, tags, agent state, summaries, translations, usage, notes, and digest data

Reasons:

- Rewriting database logic would be high effort and high risk.
- Migration correctness is critical and easy to break.
- Existing tests encode many product rules that should remain authoritative.
- The UI can change, but persisted data behavior should stay stable.

Decision: preserve and reuse database code unless Windows GRDB support proves impractical.

## Proposed Architecture

Split Mercury into three conceptual layers.

### `MercuryCore`

Pure or near-pure business logic:

- feed use cases and sync policy
- reader pipeline contracts
- markdown conversion policy
- agent runtime and state machine
- prompt/template resolution
- summary, translation, and tagging contracts
- digest composition/export policy
- task lifecycle logic
- usage report contracts

### `MercuryStore`

Persistence and database access:

- `DatabaseManager`
- migrations
- GRDB models
- feed, entry, content, tag, note, agent, translation, summary, digest, and usage stores
- query builders
- database-facing tests

### `MercuryPlatform`

Platform-specific adapters:

- credential storage
- settings storage
- file picker and export directory access
- clipboard
- share service
- font catalog
- spell checking or tag suggestion helpers
- WebView hosting
- notifications
- auto-update
- OS-specific paths and permissions

macOS can implement these adapters with AppKit/SwiftUI APIs. Windows should implement them through the chosen desktop framework and OS services.

## Windows UI Options

### Preferred: Tauri + Web UI + Swift Sidecar

This is currently the most balanced option.

Pros:

- Windows is well served by WebView2.
- Reader HTML/Markdown rendering fits naturally in a web UI.
- UI development cost is lower than native WinUI.
- The Swift core can run as a sidecar process accessed through JSON-RPC, stdin/stdout, named pipes, or a local IPC protocol.
- Linux remains possible later without designing primarily for it.

Cons:

- WebViewGTK may complicate Linux packaging.
- The app will not feel as native as the macOS SwiftUI version.
- IPC contracts must be designed and tested carefully.

### Alternative: Avalonia/.NET + Swift Sidecar

Pros:

- Stronger Windows desktop feel.
- Mature desktop controls, menus, file dialogs, and layout primitives.
- Cross-platform potential remains.

Cons:

- Larger conceptual distance from the existing Swift codebase.
- Reader content still likely needs embedded web rendering.
- More UI work than Tauri.

### Lower Priority: Electron

Electron is viable for fast validation, but currently not preferred because of package size, runtime overhead, and weaker fit with Mercury's lightweight local-first positioning.

## Swift Core Integration Strategy

Start with a Swift sidecar process instead of a Swift dynamic library or C ABI bridge.

Reasons:

- Avoids early ABI and FFI complexity on Windows.
- Keeps the database owned by one process.
- Lets the UI framework remain replaceable.
- Makes the first cross-platform proof easier to build and debug.
- Can evolve later into a tighter bridge if needed.

The sidecar should expose coarse application commands rather than leaking low-level store APIs directly to the UI.

Example command areas:

- feed CRUD and sync
- entry list queries
- reader content build/load
- summary, translation, and tagging tasks
- settings and provider/model management
- digest export preparation
- usage report queries

This sidecar strategy is intentionally a later phase. The first spike should not build the sidecar or commit to an IPC protocol. It should only answer whether the high-value Swift core assets can run on Windows.

## Module Reuse Assessment

### Must Try to Reuse

- `Readability`
- `ReaderDefaultPipeline`
- `MarkdownConverter`
- `ReaderPipelineVersion`
- `DatabaseManager`
- database migrations
- GRDB models
- `EntryStore`, `FeedStore`, `ContentStore`
- `TagLibraryStore`, `TagBatchStore`
- agent persistence stores
- usage persistence

### High-Value Reuse

- feed sync/use cases
- OPML import/export
- digest template and export policies
- agent prompt resolution
- agent runtime/state machine
- summary, translation, and tagging contracts
- task lifecycle core

### Reuse After Platform Abstraction

- settings management
- language/localization manager
- template customization file handling
- export path handling
- local tagging fallback
- document/base URL helpers

### Likely Rewrite or Platform Adapter

- SwiftUI views
- AppKit representables
- `WKWebView` wrapper
- `Charts` views
- `NSOpenPanel` / `NSSavePanel`
- `NSPasteboard`
- `NSSharingServicePicker`
- `SecurityScopedBookmark`
- `NSSpellChecker`
- `CoreText` font enumeration
- `AppIntents`
- Sparkle/update packaging

## Initial Spike Plan

The first milestone should answer one question only:

Can Mercury's `Readability` and database layer run reliably on Windows?

This should be implemented as a small, independent SwiftPM package named `MercuryPortingProbe`. It should not start by restructuring the main Mercury app, extracting production modules, or introducing a Windows UI shell. The probe exists to decide whether the cross-platform effort is worth continuing.

### Probe Scope

Include only:

- `Readability`
- `SwiftSoup`
- `GRDB`
- the smallest Mercury-style schema and migration subset needed for content persistence
- a minimal `Content` model
- one minimal `ContentStore`
- the smallest useful cleaned-HTML-to-Markdown conversion path

Avoid:

- `AppModel`
- SwiftUI or AppKit
- WebView integration
- feed sync
- agent runtime
- provider settings
- localization infrastructure
- `UserDefaults`
- security-scoped bookmarks
- sidecar IPC
- Tauri, Avalonia, or Electron integration

The probe should carry enough Mercury shape to be meaningful, but no more. In particular, it should validate a small version of:

1. source HTML
2. `Readability` parse
3. cleaned HTML, title, and byline persistence
4. Markdown conversion
5. GRDB-backed insert, query, update, and reopen behavior

### Pre-requisites and Toolchain

Before writing any probe code, pin the Windows Swift toolchain and verify the foundations.

**Swift toolchain:**

- Decide between the swift.org official toolchain and community-maintained alternatives (e.g. The Browser Company's Swift 6 Windows distribution).
- Document the exact toolchain version and install method so the spike result is reproducible.
- Verify that the chosen toolchain supports Swift 6 concurrency (`async`/`await`, `actor`, `Task`, `Sendable`) at runtime — compile-and-run a small async program, not just a build check.

**Swift Testing availability:**

- Mercury production tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`).
- Confirm whether Swift Testing is available on the chosen Windows toolchain. If not, the probe should use XCTest to avoid introducing an unsupported dependency into the feasibility gate.

**GRDB and SQLite linking:**

- GRDB on macOS links the system SQLite library. Windows has no system SQLite.
- Decide how the probe will provide SQLite: static compilation via SPM, a pre-built SQLite amalgamation, or a package manager such as vcpkg.
- Verify that the chosen approach supports WAL journal mode, which Mercury depends on for concurrent reads and writes.

**Readability dependency audit:**

- Before the probe, scan `Readability`'s imports for Darwin-specific Foundation APIs (`Darwin.C`, platform conditionals, or OSLog).
- If any are found, classify them as blockers or patchable before probe start.

Recommended steps:

1. Create a small SwiftPM porting probe package.
2. Pin dependency versions by tag or commit so the spike result is reproducible.
3. Add `Readability`, `SwiftSoup`, `GRDB`, and the smallest useful subset of Mercury database code.
4. Add a Windows CLI or test target.
5. Add tests for:
   - `Readability` fixtures: at least 3-5 HTML samples covering distinct scenarios (standard blog post, non-ASCII/Chinese encoding, nested tables, malformed markup). Fixtures should assert non-empty content and stable title/byline behavior.
   - one SQLite migration path
   - basic insert/query/update through the content store
   - one on-disk reopen case
   - one minimal Markdown conversion case with fixed expected output
   - one async/await test that exercises `Task`, actor isolation, and structured concurrency (Swift 6 concurrency runtime validation on Windows)
   - one cross-platform SQLite compatibility test: create a database file on macOS (with WAL/shm sidecars), copy it to Windows, open it, read a known record, write a new record, reopen and verify
6. Run the probe on macOS first.
7. Run the same tests on Windows.
8. Run both Debug and Release configurations when practical, because Swift and Foundation differences can appear under optimization.
9. If Windows passes, start planning real `MercuryCore` and `MercuryStore` extraction.
10. If Windows fails, classify failures into:
   - dependency issue worth patching or forking
   - Foundation/Swift-on-Windows limitation
   - Swift concurrency runtime limitation (actor isolation, async/await, Task)
   - GRDB or SQLite packaging/linking limitation
   - code-level Darwin assumption
   - unacceptable ecosystem risk

Do not expand the first spike into UI work. The UI framework choice is only useful after the probe shows that `Readability` and GRDB-backed persistence can be reused.

### Probe Tests

The first test set should be deliberately small:

- `Readability` parse fixture:
  - parse one static HTML fixture
  - assert non-empty content
  - assert stable title/byline behavior where applicable
- SQLite migration:
  - create a fresh database
  - run the probe migrator
  - assert key table, column, and index presence
- Content store:
  - insert source HTML and parsed content
  - query it back
  - update Markdown and version fields
  - close and reopen an on-disk database
  - query the same record after reopen
- Markdown conversion:
  - convert a small cleaned HTML sample
  - compare against a fixed expected Markdown string
- Swift concurrency (async/await) validation:
  - create at least one test using `async`/`await`, `actor`, and `Task`
  - this validates that the Swift 6 concurrency runtime is functional on Windows, which is essential for Mercury's agent runtime, task queue, and store access patterns
- Cross-platform SQLite file compatibility:
  - on macOS, create a database file (WAL mode enabled), insert records, and copy the `.sqlite`, `.sqlite-wal`, and `.sqlite-shm` files to Windows
  - on Windows, open the copied file, read the existing records, write one new record, close and reopen, then verify the new record persists
  - this answers the "same file format across platforms" question at the lowest possible cost

The probe should not only prove that dependencies build. It must prove that Mercury's core reader and persistence flow has a viable Windows execution path.

## Phase 1 Acceptance Criteria

Proceed with the cross-platform effort if:

- `MercuryPortingProbe` passes on Windows with `swift test`.
- `Readability` builds and passes the representative fixture test on Windows.
- `SwiftSoup` works for the minimal parsing and Markdown conversion path.
- GRDB runs the probe migration and content store tests on Windows.
- An on-disk SQLite database can be reopened and queried after writes.
- Debug and Release behavior is consistent, or any difference is understood and judged acceptable.
- Swift concurrency (async/await, actor, Task) runs correctly on Windows in at least one test.
- A SQLite database file created on macOS can be opened, read, and written on Windows, confirming cross-platform file compatibility of the persistence layer.
- Failures, if any, are small dependency or code assumptions that can be patched without turning the effort into a rewrite.

Stop or reconsider if:

- `Readability` cannot be made reliable on Windows without a large fork.
- `SwiftSoup` blocks the reader pipeline on Windows.
- GRDB or SQLite cannot support Mercury-style migrations and store APIs on Windows with acceptable effort.
- Swift concurrency runtime is not functional on Windows (crashes, hangs, or incorrect actor isolation at runtime).
- SwiftPM or Swift-on-Windows issues dominate the spike.
- The probe has to move substantial business logic into non-Swift code to pass.

This phase is the main go/no-go gate. If `Readability` and database reuse fail, a polished Windows UI plan does not preserve Mercury's core product value and should be treated as a rewrite proposal.

## Later Acceptance Criteria

After the phase 1 probe passes, broader acceptance criteria for the next phase are:

- The Swift sidecar can execute core commands with acceptable latency.
- The macOS app can continue evolving without adopting the Windows UI stack.
- The production `MercuryCore` and `MercuryStore` extraction can happen without slowing macOS development materially.
- The Windows UI shell can consume coarse commands without duplicating store invariants.

Pause or reconsider the broader effort if:

- Swift-on-Windows build, packaging, or runtime issues dominate the work.
- Too much business behavior has to move into the rewritten UI layer.

## Later Decision Memo

These topics are important, but should not block or broaden the first probe.

### Module and Repository Shape

- Should `MercuryCore` and `MercuryStore` live in the same repository as the macOS app or become separate Swift packages?
- Should they become SwiftPM targets consumed by the existing Xcode project?
- Should the first production extraction happen after the probe, or should the probe evolve into the shared package?
- How should dependency versions be pinned across Xcode and SwiftPM so macOS and Windows builds remain reproducible?

### Platform Boundaries

- Which existing core files contain platform assumptions such as `@MainActor`, `UserDefaults`, `Bundle.main`, security-scoped bookmarks, AppKit, SwiftUI, or macOS filesystem paths?
- Which assumptions should move into `MercuryPlatform` adapters?
- What is the minimum platform API needed for settings, credentials, paths, localization, file access, clipboard, notifications, and update behavior?

### Sidecar and IPC

- What IPC protocol should the Swift sidecar expose?
- Should commands use JSON-RPC, stdin/stdout, named pipes, local sockets, or another transport?
- How are request IDs, cancellation, progress events, long-running task state, logging, and crash recovery represented?
- How coarse should sidecar commands be so the UI does not duplicate store/query invariants?

### Database Compatibility

- Should Windows directly open the same SQLite file format used by macOS?
- Should the first Windows version instead support import/export before direct shared database compatibility?
- How are WAL files, migrations, backup, downgrade behavior, locking, and corruption recovery handled across platforms?
- Can one process reliably own the database for all UI operations?

### Windows Product Scope

- Which features define the first Windows MVP?
- Are feed sync, reader mode, tags, notes, summary, translation, digest export, OPML import/export, and usage reports all in scope?
- Which macOS-only integrations are intentionally omitted from v1?
- Which features require equivalent Windows OS services, and which can be simplified?

### UI Shell

- Should the Windows app use Tauri or Avalonia for the first MVP?
- Does Tauri's WebView2-based Windows behavior satisfy reader rendering, keyboard handling, accessibility, and printing/export needs?
- Is Avalonia worth the extra UI work for a more desktop-native Windows feel?
- Is Electron acceptable only for fast validation, or should it remain out of production consideration?

### Packaging and Operations

- How is the Swift sidecar bundled, signed, updated, restarted, and logged?
- How does the Windows installer ensure the required Swift runtime or sidecar binaries are present?
- How are crash reports and diagnostic logs collected without adding too much infrastructure?
- What CI matrix is required before production work starts?

## Current Recommendation

Prioritize a Windows-focused proof of feasibility around `Readability` and GRDB-backed persistence before making a UI framework commitment or refactoring the main repository.

If that proof succeeds, build the Windows version as a new desktop shell backed by shared Swift core and store modules. Keep the macOS SwiftUI app native and independent from the cross-platform UI stack.

If that proof fails, reassess whether Mercury for Windows is still a porting project or has become a rewrite project.
