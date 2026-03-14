# Mercury — Agent Engineering Notes

Reference for AI coding agents working on this codebase. Keep this file concise, prescriptive, and focused on repository-wide rules.

---

## 1. Communication and Documentation

- Communicate with the user in Chinese.
- Write code comments and repository documentation in English unless explicitly requested otherwise.
- Do not use emojis in code comments or documentation.
- Use backticks for code references in Markdown.

---

## 2. Core Stack and Naming

- Platform: macOS-first, no iOS target.
- Language: Swift.
- UI: `SwiftUI` first. Use `UIKit` / `AppKit` only when unavoidable.
- Networking: `URLSession`.
- Storage: `SQLite` + `GRDB`. `CoreData` is fallback only.
- Feed parsing: `FeedKit`.
- HTML cleaning: `SwiftSoup`.
- Article extraction: in-house `Readability`, no `WebKit` dependency.
- Markdown to HTML: `swift-markdown` + internal `MarkupHTMLVisitor` (GFM-aware). Rendered HTML is cached by `themeId + entryId` with `readerRenderVersion`; see `docs/markdown-engine.md`.
- LLM client: `SwiftOpenAI`.
- Default numeric type is `Double`; use `CGFloat` only when required by API.

Naming and file structure:

- Keep source layout flat unless a deeper module is clearly reusable.
- SwiftUI view files use `*View.swift`; view models use `*ViewModel.swift`.
- Shared agent infrastructure uses `Agent*` prefix.
- Feature-specific files use feature prefixes such as `Summary*` and `Translation*`.
- `AppModel` extensions use `AppModel+FeatureName.swift`.
- `AI*` prefixes are deprecated; use `Agent*`.

`SwiftOpenAI` routing note: request building replaces base URL path. Preserve provider paths via `overrideBaseURL + proxyPath` plus version segment when needed, otherwise compatible providers may return `404`.

---

## 3. Build and Verification

Run from repo root:

```shell
./scripts/build
```

- Do not pipe or post-process `./scripts/build` output.
- Keep the build free of compiler errors and warnings.
- If tooling returns empty or missing output, stop and ask the user to verify manually.

---

## 4. Localization Rules

Full design: `docs/l10n.md`.

- All user-visible strings must resolve through `LanguageManager.shared.bundle`.
  - Use `Text(..., bundle:)` in views.
  - Use `String(localized:..., bundle:)` or equivalent bundle-aware APIs in model/runtime code.
- Never localize debug issue strings.
- Avoid runtime-computed `LocalizedStringKey`; prefer static keys or bundle-resolved `String` values.
- `View.help()`, some `Picker` convenience initializers, and `.tabItem` ignore the environment bundle; pass pre-resolved `String` values there.
- Prefer extraction-friendly localization call sites: avoid hiding keys inside ternaries or other dynamic expressions when a static helper/property can expose each key literally.
- Do not manually edit `Localizable.xcstrings` extraction metadata such as `extractionState` / `stale`; let Xcode extraction and build tooling maintain those fields.
- Keep SwiftUI imports out of pure model files; move UI-facing label keys or presentation helpers into view-facing extensions when needed.

Must-use shared facilities:

- Reuse existing shared localization/presentation helpers when the semantics already exist.
- Do not introduce feature-local copies of prompt fallback, failure, status, or task-title wording when a shared projection/helper already covers that concept.

---

## 5. Agent Task Shared Facilities

Agent-task behavior must converge on shared infrastructure instead of re-implementing feature-local variants.

Mandatory shared facilities:

- `TaskQueue` / `TaskCenter` for background and long-running orchestration.
- `AgentRunStateMachine` for state transitions.
- `AgentRuntimeEngine` for active/waiting lifecycle management.
- `AgentRuntimeStore` for in-memory runtime indexing.
- `AgentExecutionShared` for shared route resolution and terminal recording.
- `AppTaskKind.displayTitle` for task display titles.
- `AgentRuntimeProjection` for shared user-facing failure and runtime projection logic.
- `AgentPromptCustomizationConfig` and related prompt-template facilities for prompt fallback behavior.

Hard rules:

- Do not build ad-hoc task schedulers or parallel lifecycle systems outside the shared task/runtime stack.
- Do not create task-local copies of failure-message projection when `AgentRuntimeProjection` already owns that semantic.
- Do not create task-local copies of prompt fallback wording when shared prompt-customization helpers already exist.
- Do not hard-code new task titles inside executors when `AppTaskKind.displayTitle` is available.
- When adding a new reusable agent-task semantic, extend the shared facility first instead of forking it locally in one feature.
- Do not route new app-authored string literals through a freeform message escape hatch; migration-only usage must be removed within the same unification iteration, and any truly non-structurable case requires explicit discussion.

---

## 6. Agent Runtime Contracts

Core architecture:

- `AgentRunStateMachine`: pure transitions.
- `AgentRuntimeEngine`: lifecycle driver.
- `AgentRuntimeStore`: active/waiting index.
- `AgentExecutionShared`: shared route resolution and terminal recording.

Global execution policy:

- No automatic cancellation of in-flight background runs.
- Cancellation must come from explicit user intent or a hard safety rule.

Entry activation contract:

1. Project persisted renderable state for the selected entry or slot.
2. Render that state immediately if present.
3. Evaluate run start, queue, or waiting behavior only after projection.

Queue replacement policy:

- Switching entry clears waiting runs for the previous entry.
- Waiting runs are latest-only replacement.
- In-flight runs are never auto-replaced.
- Current per-kind limit: active slot `1` plus waiting slot `1`.

Prompt-template contract:

- Built-ins live under `Resources/Agent/Prompts/*.default.yaml`.
- Sandbox overrides take priority over built-ins.
- The first custom-prompts action copies from the built-in template and must never overwrite an existing sandbox file.

Agent settings keys currently in use:

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

---

## 7. Message Surface Rules

Use one approved user-facing surface per projected message.

Surfaces:

| Surface | Usage |
|---|---|
| Modal alert | Sync user-initiated fatal action only |
| Status bar | Global app health and operation state |
| Debug Issues | Unexpected or low-level diagnostics |
| Reader banner | Entry-bound agent notifications for the currently displayed Reader content |
| Batch sheet fixed message area | Batch-tagging notices, failures, and actions during the batch lifecycle |

Mandatory rules:

- Summary, Translation, and single-entry Tagging are Reader-bound tasks and may use the Reader banner.
- Batch Tagging must not project notices or failures into the Reader banner; it uses its own sheet-local fixed message area.
- Do not log `.noModelRoute` or `.invalidConfiguration` as debug issues.
- Availability guidance should surface through the approved task host rather than ad-hoc duplicate messages.
- When a shared message-projection facility exists, reuse it; do not hand-roll feature-local banner wording.

---

## 8. Testing Rules

- Restore any modified `UserDefaults` keys in `defer`; never teardown with blind `removeObject`.
- Prefer deterministic tests; avoid sleep-based timing assertions.
- Name tests by behavior, not implementation.
- For app-module value types used in nonisolated tests, prefer explicit `nonisolated` `Equatable` witnesses and `Sendable` when needed to avoid `@MainActor` synthesis issues.

Database test rules:

- Always use the shared fixtures in `MercuryTest/DatabaseTestSupport.swift`.
- Default to `InMemoryDatabaseFixture` for repository, query, and persistence tests that do not need file-system semantics.
- Use `OnDiskDatabaseFixture` only when the test explicitly needs on-disk behavior such as multi-connection locking, read-only open, WAL behavior, or path-dependent semantics.
- Use `AppModelTestHarness` for tests that need `AppModel`; do not instantiate `AppModel()` or manage its database lifecycle directly in tests.
- Do not add `temporaryDatabasePath()` helpers, `NSTemporaryDirectory()` plus `.sqlite` paths, or single-file cleanup patterns to database tests.
- On-disk cleanup must remove the per-test temporary directory, never a single `.sqlite` file.
- If a test creates a long-lived observer or store outside `AppModelTestHarness`, stop it explicitly before fixture teardown.
- If a new database scenario is needed, extend the shared fixtures or harnesses first instead of inventing one-off lifecycle patterns.

Additional test contracts:

- The default `AppModel()` initializer is for app/runtime code only.
- In the `XCTest` host environment, the default `AppModel()` database is an in-memory shared test database; do not rely on persisted files or cross-process visibility there.
- In Mercury, the accepted `XCTest` host check is `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`.
- Do not use ambiguous zero-argument `DatabaseManager` construction for the runtime default on-disk path. Open the on-disk path explicitly, and use explicit `inMemory:` creation for in-memory databases.

Database testing design notes live in `docs/db-test.md`.

---

## 9. Feature-Specific Contracts That Must Not Drift

Translation:

- Reader-only in v1.
- Segment granularity is fixed to `p`, `ul`, and `ol` via `TranslationSegmentationContract.supportedSegmentTypes`.
- Runtime may prepend one synthetic header segment `seg_meta_title_author` to keep title and author aligned in bilingual output.
- Execution model is per-segment bounded concurrency; current setting range is `1...5`, default `3`.
- `translation_result.runStatus` tracks `running` and `succeeded`; activation and finalize flows must preserve the checkpoint contract.
- Translation changes must not break task-state evaluation, Reader UI synchronization, or resume/cancel/return-to-original toolbar semantics.

Summary:

- Auto-summary remains confirm-on-enable, 1-second debounce, serialized, and no auto-retry.
- Waiting queue remains latest-only replacement.

---

## 10. Key Behavioral Contracts

Do not change these without explicit discussion and an end-to-end impact plan.

- Batch read-state actions are query-scoped by feed scope, unread filter, and search filter; they are not page-scoped.
- Search baseline targets `Entry.title` and `Entry.summary` only.
- `unreadPinnedEntryId` is explicit keep behavior; feed switch or unread-filter toggle clears it, and non-empty search disables keep injection.
- List paths use lightweight `EntryListItem`; full `Entry` is detail-only.
- Documentation in `README.md` and in-app help is a blocking deliverable before `1.0`.

---

## 11. Local Development Defaults

Local AI integration profile:

- `baseURL`: `http://localhost:5810/v1`
- `apiKey`: `local`
- `model`: `qwen3`
- `thinkingModel`: `qwen3-thinking`
