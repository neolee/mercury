# Mercury AI Agent Notes

This file is for AI coding agents. It captures the current feature plan, baseline technical stack, and initial selection considerations. Update as the project evolves.

## Documentation Rules
- Use English for all comments and documentation, except explicitly requested otherwise.
- DO NOT use emojis in code comments or documentation.
- Use backticks `` ` `` for code references in markdown documentation.
  - Class/function/variable/property/type/library names, HTML tags, file names, specific language features (e.g., `async`/`await`), etc.

## Product Direction
Mercury is a modern, macOS-first RSS reader that prioritizes:
- Beautiful, fast reading experience
- High performance with offline capabilities
- AI assistance to auto tagging, summarization, and translation
- Local-first privacy and security

### Planned Features (MVP)
- Feed management: `RSS`/`Atom`/`JSON Feed` subscriptions
- Reading experience: three-pane layout, typography-focused article view
- AI assistance (opt-in): `auto-tag`, `translation`, single-article summary

### Planned Features (Post-MVP)
- More reading enhancements e.g. offline cache, local full-text search
- More AI assistance: multi-article summaries and topic digests

## Technical Stack (Baseline)
- Platform: `macOS`
- Language: `Swift`
- UI: `SwiftUI` (follow Apple best practices for architecture and UI)
- Networking: `URLSession`
- Storage: `SQLite` with `GRDB` (preferred) or `Core Data` (fallback)
- Rendering: `SwiftUI` text rendering with `WKWebView` fallback for complex HTML

## Initial Library Selections (Subject to Change)
- Feed parsing: `FeedKit` (RSS/Atom/JSON Feed) [https://github.com/nmdias/FeedKit](https://github.com/nmdias/FeedKit)
- HTML parsing/cleaning: `SwiftSoup` [https://github.com/scinfu/SwiftSoup](https://github.com/scinfu/SwiftSoup)
- Readability/article extraction: `swift-readability` (pure Swift, no WKWebView) [https://github.com/neolee/swift-readability](https://github.com/neolee/swift-readability)
- Markdown → HTML renderer: `Down` (cmark-gfm) [https://github.com/iwasrobbed/Down](https://github.com/iwasrobbed/Down)
- LLM client (OpenAI-compatible): `SwiftOpenAI` [https://github.com/jamesrochabrun/SwiftOpenAI](https://github.com/jamesrochabrun/SwiftOpenAI)

## AI Integration Guidelines
- Build an `LLMProvider` abstraction with support for OpenAI-compatible APIs.
- `Base URL` must be configurable to allow local model gateways in development.
- Support streaming (`SSE`) responses for progressive UI updates.
- Do not embed API keys in client builds; use local proxy/gateway for production.

## Privacy and Security Notes
- Local-first data storage.
- AI features opt-in and transparent about data use.
- Provide user controls to delete AI outputs and local data.

## Sandbox & Entitlements
- Enable App Sandbox.
- Allow network: Outgoing Connections (Client).
- Allow file access: User Selected File Read/Write (for OPML import/export and local file import).
- Do not enable additional capabilities unless a feature explicitly requires them (e.g., iCloud, Keychain Sharing, Downloads/Documents access).

## SPM Dependencies & Versions
- FeedKit: add via SPM; pin to a compatible stable version range.
- SwiftSoup: add via SPM; pin to a compatible stable version range.
- swift-readability (neolee): add via SPM; pin to a compatible stable version range.
- Down: add via SPM; pin to a compatible stable version range.
- SwiftOpenAI: add via SPM; pin to a compatible stable version range.
- GRDB: add via SPM; pin to a compatible stable version range (preferred storage).
- Review versions quarterly and update only after verifying build and behavior.

## Project Structure Guidance
- Keep the source layout flat by default; avoid deep folders unless a module is clearly reusable.
- Distinguish `View` and `ViewModel` by file naming (e.g., `ReaderView.swift`, `ReaderViewModel.swift`).
- Revisit folder structure only when file volume becomes a real maintainability issue.

## Development Principles
- Performance matters: avoid heavy `WKWebView` usage for normal reading flow.
- Keep UI crisp and keyboard-friendly.
- Follow Apple `SwiftUI` best practices for layout, state management, and architecture.
- Favor native `macOS` patterns unless a clear UX win exists.
- Numeric type policy: default to `Double` across app and UI code; only introduce `CGFloat` when an API explicitly requires it and the compiler does not auto-convert.
- Update this file whenever key technical choices change.

## Content Rendering Notes
- Render `cleanMarkdown` → `cleanHTML` with Down and cache results by `themeId + entryId` in a dedicated table.

## Build and Verification
- Build via `build`.
- Every change must keep the build free of compiler errors and warnings.

Verification rule:
- When verifying, run `./build` directly with no extra piping, redirection, or output processing.
- If the environment returns empty or missing output for `./build` (known tooling bug), stop and ask the user to verify the result manually.

## Milestone Plan
1. RSS subscription and basic reading
2. Subscription sync and reading improvements
3. AI foundation (provider abstraction, task queue)
4. Initial AI features (auto-tag, single-article summary, translation)
5. Full strengthening and integration (multi-article summaries, polish, performance)

## 1.0 Release Plan (Open)
- `Translate Agent` (Reader-only inline translation): plan in `docs/translate-agent.md`.
- `Sparkle` integration for in-app auto update flow (channel strategy, update UX, release safety checks).
- User documentation completion:
  - `README.md` production rewrite (install/setup, AI settings, privacy, troubleshooting).
  - in-app help/info entry points for key workflows and risk disclosures.

## Current Global Contracts (Post Stage 2)
- Stage status baseline:
  - Stage 1 and Stage 2 are closed.
  - New implementation work should default to Stage 3 (AI foundation) context unless explicitly requested otherwise.

- Batch read-state authoritative behavior:
  - `Mark All Read` and `Mark All Unread` are query-scoped operations.
  - Scope is defined by current feed scope (`This Feed` or `All Feeds`), unread filter, and search filter.
  - Do not treat batch actions as “loaded page only” operations.

- Search boundary and evolution:
  - Current baseline search targets are `Entry.title` and `Entry.summary` only.
  - `Content.markdown` search and `FTS5` are future evolution items; do not expand search scope implicitly.

- Unread interaction contract:
  - `unreadPinnedEntryId` is the explicit temporary keep mechanism.
  - Switching feed or toggling unread filter must clear temporary keep state.
  - When search text is non-empty, pinned-keep injection must be disabled.

- List/detail performance contract:
  - List path must use lightweight list models and list-only fields.
  - Full `Entry` payload loading is detail-only and on-demand.
  - Avoid reintroducing heavy-field overfetch in entry list queries.

- Failure surfacing policy:
  - Feed-level sync/import failures are diagnostic-first (`Debug Issues`) by default.
  - User popup alerts are reserved for workflow/file-level fatal failures requiring user action.

- Async orchestration contract:
  - Background and long-running jobs should run through `TaskQueue` / `TaskCenter` and use-case orchestration.
  - Avoid creating parallel ad-hoc task orchestration paths in UI layers.
  - Do not auto-cancel in-flight background tasks by default. Cancellation should be explicit user intent (for example pressing `Abort`) or a clearly defined hard-safety rule.
  - This non-auto-cancel policy is global and applies to auto-triggered and manually triggered task flows.

- Entry activation state-first contract (high priority):
  - On every entry activation/switch, first resolve and project renderable persisted state for that entry/slot.
  - If persisted state is available, render it immediately and complete this stage before any task-start or queue decision.
  - Only after state projection completes may the app evaluate start/queue/waiting decisions (manual or auto).
  - This ordering is authoritative and must be implemented as the shared entry-activation path, not as scattered per-entry-point guards.
  - Auto behaviors are secondary and must depend on this state-first path; they must not bypass it through parallel side paths.

- Reader detail layout stability contract:
  - In split layouts (`VSplitView` / `NavigationSplitView`), do not replace top-level pane subtrees when toggling view mode.
  - Keep pane host structure stable and switch mode by visibility/size within fixed slots.
  - Hidden slots must not keep heavyweight views active (for example `WKWebView`); use lightweight placeholders for inactive mode slots.
  - Avoid geometry-to-state feedback loops for pane size persistence unless explicitly required and test-covered.
  - For `Reader` HTML rendering via `WKWebView`, effective theme changes must be reflected by a stable view identity strategy (for example `.id(entryId + effectiveTheme.cacheThemeID)`), not only by expecting in-place `loadHTMLString` updates.

- Summary auto-run contract (Stage 3 Step 6):
  - Enabling `Auto-summary` must show a risk confirmation by default every time, with a user option to disable future prompts.
  - A global settings switch must allow users to re-enable/disable the enable-warning behavior at any time.
  - Auto trigger debounce for entry switching is fixed at `1s`.
  - Auto scheduling uses serialized strategy by default (no parallel auto-summary runs).
  - Do not auto-cancel in-flight background summary runs unless there is an explicit user abort action.
  - Auto-summary failures are surfaced to users; no automatic retry policy.
  - Manual `Summary` action has higher priority than auto scheduling, but should not implicitly abort an in-flight run.
  - For entries with no persisted summary and no in-flight run for that entry, `Target Language` and `Detail Level` should reset to `Agents` settings defaults.
  - If an entry has an in-flight summary run, controls should follow that run's slot parameters (`entryId + targetLanguage + detailLevel`) until terminal state.
  - Pre-start persisted-summary fetch check is mandatory and fail-closed:
    - fetch failure must not auto-start summary generation.
    - UI should surface `Fetch data failed. Retry?`, with retry re-running fetch/check first.
  - Queued auto behavior uses latest-only replacement (strategy A):
    - waiting entries can be dropped if user leaves before start.
    - latest selected eligible entry replaces earlier queued auto candidate.
  - Batch-generation intent should be handled by dedicated multi-entry features (for example unread digest), not by changing single-entry auto queue semantics.

- Summary prompt customization contract:
  - `Agents > Summary` should expose `custom prompts` action instead of inline prompt text editing.
  - First invocation creates sandbox `summary.yaml` from built-in `summary.default.yaml`; existing file must be preserved.
  - Prompt loading prefers sandbox `summary.yaml` when present, and falls back to built-in template when absent.
  - Editing workflow is user-managed outside app UI (for example reveal in Finder and edit with external tools).

- Translation agent baseline contract (planned, pre-1.0):
  - Translation is `Reader`-only in v1 (no `Web`/`Dual` translation mode).
  - Reader translation mode renders source segments with inline translated blocks.
  - Segment baseline is `p` / `ul` / `ol` block granularity.
  - `Agents > Translation` should provide primary/fallback model, default target language, and `custom prompts` external-edit workflow.
  - Reader toolbar should provide `Share` actions (`Copy Link`, `Open in Default Browser`) as a complementary path for browser-based translation workflows.

- Agent error UX contract (global):
  - Error detail should be centralized in one explicit error surface (top banner in Reader detail), shown only on actual failure.
  - Avoid duplicate failure detail in multiple panes at the same time; inline areas should keep neutral empty-state text.
  - Neutral placeholders baseline: use `No summary` and `No translation` for empty/failure content states unless a feature explicitly requires richer copy.
  - Do not use question-form retry text (for example `Retry?`) unless there is an immediate actionable retry control in the same UI context.
  - In translation mode, empty translated state should still keep translation blocks visible, so mode intent remains clear.
  - Clear stale error surfaces on new run start, run success, and entry switch to prevent cross-entry carry-over confusion.

- Documentation governance:
  - Before `1.0`, release documentation (`README.md` and in-app info/help copy) must be treated as a blocking deliverable, not a deferred placeholder.
  - Stage acceptance and closure should be tracked in stage docs and validated by `./build`.
