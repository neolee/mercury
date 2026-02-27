# Mercury — Agent Engineering Notes

Reference for AI coding agents working on this codebase. Keep this file concise and accurate.

---

## Documentation Rules

- English for all code comments and documentation unless explicitly requested otherwise.
- No emojis in code comments or documentation.
- Use backticks for all code references in Markdown.

---

## Technical Baseline

| Area | Choice | Notes |
|---|---|---|
| Platform | macOS | macOS-first; no iOS target |
| Language | Swift | Latest stable |
| UI | `SwiftUI` | Use `UIKit` / `AppKit` only when unavoidable |
| Networking | `URLSession` | No third-party HTTP layer |
| Storage | `SQLite` + `GRDB` | `CoreData` is fallback only |
| Feed parsing | `FeedKit` | `RSS` / `Atom` / `JSON` Feed |
| HTML cleaning | `SwiftSoup` | |
| Article extraction | in-house `Readability` | Pure Swift, no `WebKit` dependency |
| Markdown -> HTML | `Down` (`cmark-gfm`) | Cache by `themeId + entryId` |
| LLM client | `SwiftOpenAI` | OpenAI-compatible; base URL configurable |

Numeric policy: default to `Double`; use `CGFloat` only when an API requires it.

`SwiftOpenAI` routing note: request building replaces base URL path. Preserve provider paths via `overrideBaseURL + proxyPath` (+ version segment), otherwise compatible providers may return `404`.

---

## Build and Verification

Run from repo root:

```shell
./scripts/build
```

- Do not pipe or post-process `./scripts/build` output.
- Keep the build free of compiler errors and warnings.
- If tooling returns empty/missing output, stop and ask the user to verify manually.

---

## Project Structure

- Keep source layout flat unless a deeper module is clearly reusable.
- SwiftUI view files use `*View.swift`; view models use `*ViewModel.swift`.
- Shared agent infrastructure uses `Agent*` prefix.
- Feature-specific files use feature prefixes (e.g., `Summary*`, `Translation*`).
- `AppModel` extensions use `AppModel+FeatureName.swift`.
- `AI*` prefixes are deprecated; use `Agent*`.

---

## Localization Rules

Full design: `docs/l10n.md`.

- All user-visible strings must resolve through `LanguageManager.shared.bundle` (`Text(..., bundle:)` in views, `String(localized:..., bundle:)` in model/runtime code).
- Never localize debug issue strings.
- Avoid runtime-computed `LocalizedStringKey`; use static `labelKey` properties.
- `View.help()`, some `Picker` convenience initializers, and `.tabItem` ignore the environment bundle; pass pre-resolved `String` values.
- Keep SwiftUI imports out of pure model files; add UI-facing `labelKey` in `Views/` extensions.

---

## Testing Rules

- Restore any modified `UserDefaults` keys in `defer`; never teardown with blind `removeObject`.
- Prefer deterministic tests; avoid sleep-based timing assertions.
- Name tests by behavior, not implementation.
- For app-module value types used in nonisolated tests, prefer explicit `nonisolated` `Equatable` witnesses (and `Sendable`) to avoid `@MainActor` synthesis issues.

Local AI integration profile:
- `baseURL`: `http://localhost:5810/v1`
- `apiKey`: `local`
- `model`: `qwen3`
- `thinkingModel`: `qwen3-thinking`

---

## Agent Runtime Contracts

### Core architecture

- `AgentRunStateMachine`: pure transitions.
- `AgentRuntimeEngine`: lifecycle driver.
- `AgentRuntimeStore`: in-memory active/waiting index.
- `AppModel+SummaryExecution` / `AppModel+TranslationExecution`: orchestration entry points.
- `AgentExecutionShared`: shared route resolution and terminal recording.

### Global execution policy

- No automatic cancellation of in-flight background runs.
- Cancellation must come from explicit user intent or a hard safety rule.

### Entry activation contract

On entry switch/activation, always:
1. Project persisted renderable state for the selected entry/slot.
2. Render that state immediately if present.
3. Evaluate run-start / queue / waiting behavior only after projection.

### Queue replacement policy

- Switching entry clears waiting runs for the previous entry.
- Waiting runs are latest-only replacement.
- In-flight runs are never auto-replaced.
- Current per-kind limit: active slot `1` + waiting slot `1`.

### Agent settings keys (`UserDefaults`)

| Setting | Key |
|---|---|
| Summary target language | `Agent.Summary.DefaultTargetLanguage` |
| Summary detail level | `Agent.Summary.DefaultDetailLevel` |
| Summary primary model | `Agent.Summary.PrimaryModelId` |
| Summary fallback model | `Agent.Summary.FallbackModelId` |
| Translation target language | `Agent.Translation.DefaultTargetLanguage` |
| Translation primary model | `Agent.Translation.PrimaryModelId` |
| Translation fallback model | `Agent.Translation.FallbackModelId` |
| Translation concurrency degree | `Agent.Translation.concurrencyDegree` |

### Prompt templates

- Built-ins: `Resources/Agent/Prompts/*.default.yaml`.
- Sandbox overrides have priority over built-ins.
- First "custom prompts" action copies from built-in; never overwrite an existing sandbox file.

### Translation-specific contracts

- Reader-only in v1.
- Segment granularity is fixed to `p` / `ul` / `ol` (`TranslationSegmentationContract.supportedSegmentTypes`).
- Runtime may prepend one synthetic header segment (`seg_meta_title_author`) to keep title/author aligned in bilingual output.
- Execution model is per-segment bounded concurrency; current setting range is `1...5`, default `3`.
- Phase-4 checkpoint persistence is active:
  - `translation_result.runStatus` tracks `running` / `succeeded`.
  - active runs checkpoint per segment.
  - successful finalize must reuse run identity and flip `runStatus` to `succeeded`.
  - activation must detect orphaned `running` rows and recover/cleanup safely.
- Changes to translation data flow must not break:
  - overall task-state evaluation,
  - Reader UI state synchronization,
  - resume/cancel/return-to-original toolbar semantics.

---

## Error Surface Rules

Use only one user-facing surface per failure:

| Surface | Usage |
|---|---|
| Modal alert | sync user-initiated fatal action only |
| Status bar | global app health and operation state |
| Debug Issues | diagnostics for unexpected/low-level failures |
| Reader banner | all Reader/agent user-facing notifications |

Mandatory rules:
- Agent run failures (`summary`/`translation`) surface in Reader banner only.
- `FailurePolicy.shouldSurfaceFailureToUser(kind:)` must remain `false` for `.summary` and `.translation`.
- Do not log `.noModelRoute` / `.invalidConfiguration` as debug issues.
- Availability guidance banners are shown only on entry load (empty content + unavailable) or explicit user action.

---

## Key Behavioral Contracts

Do not change these without explicit discussion and an end-to-end impact plan.

- Batch read-state actions are query-scoped (feed scope + unread filter + search filter), not page-scoped.
- Search baseline targets `Entry.title` + `Entry.summary` only.
- `unreadPinnedEntryId` is explicit keep behavior; feed switch/unread-filter toggle clears it; non-empty search disables keep injection.
- List path uses lightweight `EntryListItem`; full `Entry` is detail-only.
- Background/long-running orchestration goes through `TaskQueue` / `TaskCenter`, not ad-hoc UI tasks.
- Summary auto-run: confirm-on-enable, 1s debounce, serialized, no auto-retry, waiting queue latest-only replacement.
- Documentation (`README.md` and in-app help) is a blocking deliverable before 1.0.
