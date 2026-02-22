# Mercury — Agent Engineering Notes

Reference for AI coding agents working on this codebase. Keep this file accurate and concise; update whenever key technical decisions change.

---

## Documentation Rules

- English for all code comments and documentation unless explicitly requested otherwise.
- No emojis in code comments or documentation.
- Use backticks for all code references in Markdown: type names, function names, files, language features, etc.

---

## Technical Stack

| Area | Choice | Notes |
|---|---|---|
| Platform | macOS | macOS-first; no iOS targets planned |
| Language | Swift | Latest stable |
| UI | SwiftUI | Follow Apple best practices; avoid UIKit/AppKit unless unavoidable |
| Networking | URLSession | No third-party HTTP layer |
| Storage | SQLite + GRDB | Preferred; Core Data is fallback only |
| Rendering | SwiftUI text / WKWebView | WKWebView is fallback for complex HTML; avoid for normal reading flow |
| Feed parsing | FeedKit | RSS / Atom / JSON Feed |
| HTML cleaning | SwiftSoup | |
| Article extraction | In-house Readability | Pure Swift port of Mozilla Readability JS; depends only on SwiftSoup; no WebKit; passes all Mozilla unit and real-world page tests |
| Markdown → HTML | Down (cmark-gfm) | Cache results by `themeId + entryId` |
| LLM client | SwiftOpenAI | OpenAI-compatible; base URL must be configurable |

**Numeric type policy**: default to `Double` across app and UI code; introduce `CGFloat` only when an API explicitly requires it and the compiler will not auto-convert.

**SwiftOpenAI routing note**: SwiftOpenAI replaces the base URL path during request building. Preserve the provider path by mapping to `overrideBaseURL + proxyPath` (+ version segment). Incorrect mapping causes 404s for compatible-mode providers.

---

## Sandbox & Entitlements

- Enable App Sandbox.
- Allow network: Outgoing Connections (Client).
- Allow file access: User Selected File Read/Write (OPML import/export and local file import).
- Do not enable additional capabilities unless a feature explicitly requires them.

---

## Build and Verification

```
./scripts/build
```

- Run `./scripts/build` directly from the repo root; no piping, redirection, or output processing.
- Every change must keep the build free of compiler errors and warnings.
- If the environment returns empty or missing output (known tooling bug), stop and ask the user to verify manually.
- Stage acceptance requires a clean `./scripts/build` run.

---

## Project Structure

- Keep the source layout flat by default; avoid deep folders unless a module is clearly reusable.
- File naming: `ReaderView.swift` / `ReaderViewModel.swift` pattern — suffix `View` for SwiftUI views, `ViewModel` for their models.
- Shared agent infrastructure: `Agent*` prefix (e.g., `AgentRunCore.swift`).
- Feature-specific files: agent-name prefix (e.g., `SummaryPolicy.swift`, `TranslationContracts.swift`).
- `AppModel` extensions: `AppModel+FeatureName.swift` — no `AI` prefix.
- Do not use `AI*` prefixes; they are deprecated in favor of `Agent*`.

---

## SwiftUI — Critical Lessons

### `@Binding` vs `let` in async contexts

Capturing a `@Binding` value inside an async closure or `Task` reads the **live** binding on every access. Pass the value as a `let` constant before entering the async scope if snapshot semantics are needed. Mixing capture modes causes subtle race conditions where a toggle reverts mid-operation.

### Toolbar item ordering in decomposed views

`.toolbar` items defined in child views compose in declaration order. When a toolbar is split across a parent view and an extension, items from the extension appear after the parent's items. To control order precisely, move all toolbar items into a single location or use `ToolbarItemGroup` with explicit placement.

### Split pane stability

In `VSplitView` / `NavigationSplitView`, never replace a top-level pane subtree when toggling view mode. Keep the pane host structure stable and switch by visibility or size within fixed slots. Hidden slots must not keep heavyweight views active (e.g., `WKWebView`); use lightweight placeholders. Avoid geometry-to-state feedback loops for pane-size persistence unless explicitly required and test-covered.

### Custom `SplitDivider` control

SwiftUI's built-in split views cannot accurately position the divider line between panes. For precise pane size control and restoration (e.g., the summary pane), use the in-house `SplitDivider` control. The current implementation supports the vertical (V) direction; a horizontal (H) direction can be built by following the same pattern. `SplitDivider` is highly reusable — prefer it over any native split-view divider whenever exact sizing matters.

### `WKWebView` identity and theme changes

For `WKWebView`-rendered HTML, effective theme changes must be reflected by a stable view identity strategy: `.id(entryId + effectiveTheme.cacheThemeID)`. Relying solely on in-place `loadHTMLString` updates after a theme change does not reliably refresh the rendered content.

### State normalization must stay in sync with persistence

Whenever a value is persisted (database, `UserDefaults`), the in-memory `@Published` state must be updated in the same operation or in the confirmed completion callback — never assumed to be updated by SwiftUI reactivity alone. Divergence between persisted and in-memory state causes ghost UI states that only appear after a relaunch.

---

## Testing Standards

### UserDefaults isolation

Tests that read or write `UserDefaults` must save the original values before the test and restore them in a `defer` block. Using `removeObject(forKey:)` as teardown silently destroys real user settings. Pattern:

```swift
let originalValue = UserDefaults.standard.string(forKey: key)
defer {
    if let v = originalValue { UserDefaults.standard.set(v, forKey: key) }
    else { UserDefaults.standard.removeObject(forKey: key) }
}
```

### General unit test rules

- Do not share mutable global state across test cases without explicit setup/teardown.
- Prefer deterministic synchronous tests over async sleep-based waiting.
- Name tests after the behavior they verify, not the implementation detail.

### Local AI integration test profile

- `baseURL`: `http://localhost:5810/v1`
- `apiKey`: `local`
- `model`: `qwen3`
- `thinkingModel`: `qwen3-thinking`

---

## Debugging Principles

**Root cause first**: Before fixing a symptom, identify the structural reason it exists. A fix that only patches the symptom leaves the root cause to surface elsewhere.

**Asymmetry is a signal**: When two similar features behave differently (one resets, one does not; one crashes, one does not), the asymmetry almost always points to a missing or extra step in the diverging path. Audit both paths side by side before touching either.

**Write path, not read path**: Most persistent bugs live in the write path (what gets stored, when, with what value). The read path only exposes them. Trace the write when debugging display anomalies.

**Async lifetime discipline**: Every `Task` or continuation that captures `self` must account for the lifetime of the capture. Cancellation, deallocation, and re-entry are all real in a SwiftUI + async/await codebase. A closure that runs "after the user navigated away" is the norm, not the exception.

**Pre-register before async engine calls**: Any view-side state that an event handler must read in order to correctly process an event (e.g., a payload map entry) must be written **synchronously on MainActor before** the `Task { await engine.submit(...) }` is dispatched—not inside the Task after the await returns. `submit()` emits `.activated` synchronously inside the actor; the event stream delivers it asynchronously to observers; the Task continuation has at least one additional actor hop before it can update MainActor state. That gap means the event can arrive first. If the event handler finds stale or absent state, any defensive `finish(.cancelled)` it fires releases the concurrency slot engine-wide, with cascading effects.

**Safety-net `finish(.cancelled)` calls have engine-wide scope**: A branch that calls `finish(.cancelled)` as a defensive cleanup (e.g., "no payload found, release the slot") frees a concurrency slot, which may immediately unblock a waiting run. Such branches must be audited to confirm they are unreachable during normal operation. When a normal path includes an async gap before it populates the state the handler checks, the defensive branch becomes a normal-path trigger.

**Double-start guards when two async paths converge**: When an event-stream path and a Task-continuation path can both legitimately call `startSummaryRun` (or equivalent) for the same owner, both must check `summaryRunningOwner != owner` before proceeding. The first path to arrive claims the run; the second is a no-op. Without this guard, both paths start independent runs and the second overwrites all running-entry sentinels.

---

## Agent Runtime Architecture

### Core design

- `AgentRunStateMachine`: pure state transitions; no I/O.
- `AgentRuntimeEngine`: drives the state machine; owns task lifecycle.
- `AgentRuntimeStore`: in-memory indexed store of active/waiting runs.
- `AppModel+SummaryExecution` / `AppModel+TranslationExecution`: orchestration entry points.
- `AgentExecutionShared`: shared route resolution and terminal run recording utilities.

### Non-auto-cancel policy (global)

Do not auto-cancel in-flight background tasks. Cancellation must be explicit user intent (e.g., pressing `Abort`) or a clearly defined hard-safety rule. This applies to both auto-triggered and manually triggered task flows.

### Entry activation: state-first contract

On every entry activation/switch:
1. Resolve and project renderable persisted state for that entry/slot first.
2. If persisted state is available, render it immediately and complete this stage.
3. Only after state projection completes may the app evaluate start/queue/waiting decisions.

Auto behaviors are secondary and must depend on this state-first path; they must not bypass it through parallel side paths.

### Queue replacement semantics

- Entry switch clears any waiting run for the **previous** entry.
- Latest-only replacement: a new waiting auto candidate replaces the previous waiting candidate.
- In-flight runs are never auto-replaced; only waiting runs are subject to replacement.
- Per-kind depth limit: the waiting queue and the active slot are each capped at 1 per task kind. This limit may be relaxed in a future iteration.

### LLM provider integration

- `LLMProvider` abstraction wraps `SwiftOpenAI`; base URL is configurable.
- Streaming (`SSE`) is the default; non-streaming is fallback.
- Do not embed API keys in builds; use a local proxy/gateway.

### Agent settings keys

| Setting | UserDefaults Key |
|---|---|
| Translation target language | `Agent.Translation.targetLanguage` |
| Translation primary model | `Agent.Translation.primaryModel` |
| Translation fallback model | `Agent.Translation.fallbackModel` |
| Summary detail level | `Agent.Summary.detailLevel` |
| Summary target language | `Agent.Summary.targetLanguage` |

### Prompt templates

- Built-in templates live in `Resources/Agent/Prompts/` as `*.default.yaml`.
- Sandbox overrides live in the app container; loading prefers sandbox, falls back to built-in.
- First `custom prompts` action creates the sandbox copy from the built-in template; existing sandbox file is never overwritten.

---

## Error Surface Hierarchy

Mercury uses four distinct error surfaces. Do not mix them.

| Surface | When to use | Agent runs |
|---|---|---|
| **Modal alert** | User-initiated synchronous operation that failed and requires immediate action (e.g. OPML import failure, file write failure). Never for async / background results. | Never |
| **Status bar** | App-level health and global operation outcomes: feed sync state, OPML import/export, database-level errors. | Never |
| **Debug Issues** | Failures with diagnostic value worth preserving for developer inspection, where the full error context does not fit in the UI. Reserve for unexpected or low-level failures. | Only for non-configuration failures (network, parser, storage, unknown). Do **not** write `.noModelRoute` / `.invalidConfiguration` — these are expected user-configurable states, not anomalies. |
| **Reader banner** | All in-reader notifications: agent availability guidance, run failure messages, fetch failures. The single user-facing surface for everything that happens inside Reader and its agent features. | Always |

### Enforcement rules

- `FailurePolicy.shouldSurfaceFailureToUser(kind:)` must return `false` for `.summary` and `.translation`. Their failures are fully handled by the Reader banner.
- `AppModel+SummaryExecution` and `AppModel+TranslationExecution` must skip `reportDebugIssue` when `failureReason == .noModelRoute`. A missing route is a configuration state, not a diagnostic anomaly.
- The Reader banner is the **only** output path for agent run failures. No parallel writes to the status bar or modal system.

### Agent availability banner trigger points

Show the availability guidance banner in Reader **only** at:
1. Entry load — if `summaryText.isEmpty` and `isSummaryAgentAvailable == false`.
2. User action — if the run or translate button is pressed and the respective agent is not available.

Do **not** push the availability banner reactively on `onChange(of: isSummaryAgentAvailable)` or `onChange(of: isTranslationAgentAvailable)`. Proactive injection while the user is reading existing content is disruptive without benefit.

---

## Key Behavioral Contracts

Do not change these without explicit discussion and a plan covering all affected paths.

**Batch read-state**: `Mark All Read` / `Mark All Unread` are query-scoped; scope = feed scope + unread filter + search filter. Not page-scoped.

**Search scope**: current baseline targets `Entry.title` and `Entry.summary` only. FTS5 full-text search (including `Content.markdown`) is a planned future evolution — do not add it implicitly or ahead of schedule, but do not treat the current scope as a permanent architectural constraint.

**Unread pinning**: `unreadPinnedEntryId` is the explicit keep mechanism. Feed switch or unread-filter toggle clears it. Non-empty search text disables pinned-keep injection.

**List/detail performance**: list path uses lightweight `EntryListItem`; full `Entry` is detail-only, loaded on demand. No heavy fields in list queries.

**Failure surfacing**: see **Error Surface Hierarchy** above. Feed-level sync/import failures are diagnostic-first (`Debug Issues`). Popup alerts are reserved for workflow-fatal, user-initiated operation failures only.

**Async orchestration**: background and long-running jobs run through `TaskQueue` / `TaskCenter`. No parallel ad-hoc task orchestration in UI layers.

**Agent error UX**: all agent run failures (network, auth, no route, parser, etc.) surface exclusively in the Reader top banner. Status bar and modal alerts are never used for agent outcomes. Neutral placeholders: `No summary`, `No translation`. No question-form retry text without an immediate retry control.

**Summary auto-run**: confirm dialog on every enable (user can suppress). Debounce 1 s. Serialized (no parallel auto-summary). No auto-retry on failure. Queued auto uses latest-only replacement.

**Translation**: Reader-only in v1. Segment granularity: `p` / `ul` / `ol` blocks. Share actions (`Copy Link`, `Open in Default Browser`) complement browser-based workflows.

**Documentation governance**: `README.md` and in-app help copy are blocking deliverables before 1.0, not deferred placeholders. Stage acceptance requires `./scripts/build` validation.
