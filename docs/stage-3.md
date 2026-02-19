# Stage 3 — AI Foundation + Reader Theme Customization (Plan)

> Date: 2026-02-15
> Last updated: 2026-02-19
> Scope: Stage 3 AI foundation, with one Pre-S3 UX enhancement for reader themes

This document defines the next major implementation phase after Stage 1 and Stage 2 closure.

Stage 3 has two parts:
1. A **Pre-S3 task** to improve the reading experience with customizable reader themes.
2. The **Stage 3 AI foundation** for local-first, no-login, multi-provider and multi-model AI workflows.

Current status:
- Pre-S3 reader theme work is complete.
- Active implementation should start from Stage 3 AI foundation (Phase 2 in this document).
- Summary agent track status:
  - Step 1-5 completed.
  - Step 6-7 pending (auto-summary behavior + final acceptance/doc freeze).
  - Step 6 policy baseline:
    - `Auto-summary` enable warning is shown by default on each enable action (user can opt out and restore from settings).
    - debounce is `1s`.
    - default scheduler strategy is serialized (no parallel auto-summary runs).
    - follows global non-auto-cancel policy for in-flight tasks (explicit user abort only unless documented safety rule).
    - persisted-summary pre-start fetch is fail-closed; on fetch failure show `Fetch data failed. Retry?` and do not auto-start.
    - queued auto behavior is latest-only replacement (strategy A): leaving a waiting entry drops that queued candidate.
    - future batch generation needs should be addressed by dedicated batch summary features (for example unread digest), not by changing single-entry auto queue semantics.

Reader theme Step 0 detailed design memo:
- see `docs/theme.md`

## 1. Pre-S3 Task — Reader Theme Customization

## 1.1 Goal
Before AI features, improve `Reader` mode with practical visual customization while keeping UX simple.

## 1.2 Requirements
- Add built-in reader theme presets:
  - `Light`
  - `Dark`
  - A paper-like preset (for simulated book-page reading)
- Support automatic dark mode behavior:
  - `Auto` mode follows system appearance
  - when system switches to dark appearance, reader theme should switch to the dark variant automatically
- Support simple customization controls:
  - font family selection (small curated list)
  - base font size
  - line height
  - content width
  - text/background color tuning (simple controls, no complex editor)

## 1.3 UX constraints
- Keep defaults usable without manual setup.
- Keep controls lightweight and discoverable in the existing reader toolbar or a compact popover.
- Do not introduce a complex "theme designer" in this phase.

## 1.4 Engineering notes
- Extend current theme handling (currently `themeId`) to support:
  - preset themes
  - optional per-user overrides
  - `Auto` system-follow strategy
- Keep rendering path in `ReaderHTMLRenderer` and maintain cache key compatibility by incorporating effective theme identity.
- Persist user theme settings locally.

---

## 2. Stage 3 Vision

Build an AI assistant that is:
- local-first in configuration and data storage
- no-login by default
- powerful but simple in daily use
- cost-aware via task-specific model routing

AI should enhance reading workflows without introducing heavy setup burden or noisy UI.

Stage 3 local-first policy (authoritative):
- Mercury has no backend server and requires no account/login.
- The app is usable directly after install.
- AI credentials are user-provided and stored on device only.
- Stage 3 default credential strategy is `Keychain` storage, not cloud synchronization.

## 3. Product Features (Stage 3 Scope)

## 3.1 Core single-article AI capabilities
- `auto-tag` for article categorization and labeling
- single-article summary (short and normal variants)
- translation with selectable target language

## 3.2 Multi-model routing (key differentiator)
Allow multiple configured models and route by task type. Examples:
- use a smaller/cheaper local model for bulk `auto-tag`
- use a higher-quality model for translation or high-value summaries

Task-to-model routing should be configurable, explicit, and easy to understand.

## 3.3 Local-first provider configuration
- No account system required.
- Configuration is stored locally on device.
- Support multiple provider profiles (for local gateway, cloud-compatible endpoint, test endpoint).
- Support enabling/disabling profiles quickly.
- Keep setup minimal for individual users (single profile should be enough for first success).

## 3.4 AI result lifecycle
- Save AI outputs locally and associate with `entryId`.
- Allow re-run with a different model.
- Allow deletion of AI outputs.
- Show minimal provenance metadata (provider profile, model, timestamp).

---

## 4. Key Technical Design

## 4.1 Architecture layers
- `LLMProvider` abstraction:
  - unified request/streaming interface
  - provider-specific adapters hidden behind protocol
- `AIOrchestrator`:
  - task scheduling
  - model resolution by task type
  - retry and error mapping
- `PromptBuilder`:
  - task-specific prompt templates
  - output-format constraints

- `CredentialStore`:
  - protocol abstraction for secret read/write/delete
  - default implementation uses macOS `Keychain`
  - business/data layer stores only secret references, never raw keys

## 4.2 Task orchestration and execution
- Reuse `TaskQueue` / `TaskCenter` for all AI jobs.
- AI jobs must be cancellable, progress-reporting, and debuggable.
- Avoid ad-hoc parallel execution paths in UI.

## 4.3 Data model additions (local)
Recommended new entities:
- `AIProviderProfile`
  - endpoint/base URL
  - `apiKeyRef` (reference key used by `CredentialStore`)
  - enabled state
- `AIModelProfile`
  - model name
  - provider profile reference
  - model options (for example temperature/top-p/maxTokens/stream)
  - capability flags (tagging/summary/translation)
- `AIAssistantProfile` (or `AIAgentProfile`)
  - assistant/agent identity and task type
  - system prompt template
  - optional output constraints/style hints
  - default model override (optional)
- `AITaskRouting`
  - mapping from task type/assistant to preferred model profile
  - optional fallback model profile
- `AIResult`
  - `entryId`, task type, output payload, language (if translation), model metadata, created time

All AI-related data should remain local-first.

Recommended minimum schema contract for Stage 3 kickoff:
- Provider: `baseURL + apiKeyRef + isEnabled`
- Model: `modelName + modelOptions + providerProfileId + isEnabled`
- Assistant/Agent: `taskType + systemPrompt + outputStyle + defaultModelProfileId?`
- Routing: `taskType -> modelProfileId (+ fallbackModelProfileId?)`

## 4.4 Streaming and rendering
- Support `SSE` streaming for progressive updates.
- UI should display incremental output for long responses.
- Persist final stable output only after completion.

## 4.5 Security and privacy
- Do not hardcode API keys in client builds.
- For production/team scenarios, local proxy/gateway remains an optional advanced mode.
- Provide clear user messaging about what text is sent to selected AI endpoints.

Credential handling policy for Stage 3:
- Default mode: direct provider access with user-supplied API key stored in `Keychain`.
- Persist only `apiKeyRef` in local database/preferences.
- Never store raw API key in SQLite, `UserDefaults`, debug logs, or exported files.
- Redact credentials in error messages and diagnostics.

Sandbox and entitlement notes:
- Reading/writing app-owned `Keychain` items works under App Sandbox by default.
- No extra entitlement is required for app-local key storage.
- `Keychain Sharing` capability is not required and should remain disabled unless cross-app/shared-group credentials are explicitly needed in the future.

---

## 5. AI Configuration UX (Layered, not single-page)

## 5.1 Design goals
- Keep first-run path short: configure once, then AI should work quietly in reading flows.
- Separate concerns by layer (`provider`, `model`, `agent/task`) to avoid overload.
- Preserve advanced control without exposing all options upfront.

## 5.2 IA and page layering
`AI Settings` should be a dedicated area with internal sections (left list or segmented top-level switch):

1. **Provider**
- Provider profile list (create/edit/enable/disable/delete).
- Fields: display name, base URL, auth mode, API key reference status.
- Actions: save key to `Keychain`, test connection, view last failure.
- Built-in local preset shortcut (`localhost` profile) for quick start.

2. **Model**
- Model profile list bound to a provider profile.
- Fields: model name, stream default, temperature/top-p/max tokens, capability flags.
- Actions: test model chat (multi-turn test panel), duplicate model profile.

3. **Agent & Task**
- Agent profile editor per task type (`translation`, `summary`, `tagging`).
- Fields: system prompt, output style, task-specific options, default/fallback model binding.
- Routing matrix view: task -> primary model -> optional fallback model.

4. **Diagnostics (no dedicated subpage in MVP)**
- Do not add a separate diagnostics page in MVP.
- Keep diagnostics unified in existing global `Debug Issues` view.
- In AI settings inline errors, provide a direct action to open `Debug Issues`.

## 5.3 Required interaction flows
1. **First-run flow**
- Open `Provider` -> create profile -> input API key -> run connection test.
- Open `Model` -> create model profile -> run test chat.
- Open `Agent & Task` -> assign models and save defaults.

2. **Cold-start local model flow**
- Connection/model test timeout baseline should be long enough for on-demand model loading (`120s`).
- UI should show explicit "first run may be slow" copy and in-progress state.

3. **Failure flow**
- Inline error appears in the current panel.
- Failure is written to unified `Debug Issues` with provider/model context.
- Inline error should provide an action to open `Debug Issues`.
- Success stays silent except in panel-local status text.

## 5.4 Settings simplicity principles
- Keep required fields minimal for first success.
- Hide advanced options behind "Advanced" disclosure per panel.
- Avoid cross-panel hard dependencies in a single form submit.
- Make each panel independently saveable and testable.

## 5.5 AI Settings behavior contract (implementation baseline)

This subsection is the UI/interaction baseline for Stage 3 AI Settings implementation and refactors.

1. **List behavior and ordering**
- `Provider` and `Model` lists must follow the same ordering contract:
  - default item first;
  - remaining items sorted by display name (case-insensitive);
  - if name ties, newest `updatedAt` first.
- List ordering is a UI responsibility; storage/query order must not be treated as authoritative presentation order.

2. **Toolbar action standards (`+`, `-`, `Set as Default`)**
- `+` creates a new draft form state and clears current selection for that panel.
- `-` is enabled only when a non-default item is selected.
- `Set as Default` is enabled only when a selected item exists and is not already default.
- Destructive actions must require explicit confirmation.

3. **Panel action standards (`Save`, `Reset`, `Test`)**
- `Save`: persist only that panel's owned configuration fields.
- `Reset`: if no selected profile, reset to panel defaults; if selected profile exists, restore form from selected profile.
- `Test`: must run on latest saved config; if needed, auto-save silently before testing.
- `Test` loading state must disable only its own test action (not unrelated controls).

4. **Default semantics**
- Exactly one default `Provider` and one default `Model` should exist when corresponding profile sets are non-empty.
- Default items are non-deletable.
- When a default changes, UI badges/markers and list ordering must update immediately.

5. **Cross-panel synchronization rules**
- `Model.Provider` picker options must always reflect latest provider list (rename/add/delete/default change).
- If no model profile is selected (draft/new mode), `Model.Provider` must track current default provider.
- If currently selected provider value becomes invalid (e.g., provider deleted), fallback to current default provider.
- Provider deletions must rebind dependent models to a valid default provider before completion.

6. **Status and diagnostics rules**
- Success feedback is lightweight and local to panel status text.
- Failure feedback appears inline and writes diagnostics to unified `Debug Issues` (no separate AI diagnostics page in MVP).
- Inline failure messaging should remain concise and action-oriented.

---

## 6. Implementation Plan (Step-by-step)

## Phase 0 — Design freeze and schema draft
- Finalize Pre-S3 theme UX and AI settings information architecture.
- Define AI data schema and migration plan.
- Finalize `LLMProvider` protocol and task-routing contract.

## Phase 1 — Pre-S3 reader themes
- Implement built-in presets and `Auto` system-follow behavior.
- Implement simple typography and color customization controls.
- Persist reader theme preferences and ensure stable rendering.
- Verify `ReaderHTMLRenderer` cache behavior with effective theme identity.

## Phase 2 — AI infrastructure foundation
- **Phase 2.1 — Core contracts and storage**
  - Implement `LLMProvider`, `CredentialStore`, `AIOrchestrator` protocol contracts.
  - Add schema/migrations for `AIProviderProfile`, `AIModelProfile`, `AIAssistantProfile`, `AITaskRouting`.
  - Implement `KeychainCredentialStore` and `apiKeyRef` lifecycle.
- **Phase 2.2 — First provider path and validation**
  - Implement first provider adapter (SwiftOpenAI-based) behind `LLMProvider`.
  - Validate base URL compatibility and streaming/cancel/error mapping behavior.
  - Validate against the local development profile in section 10.
  - Add provider/model validation pipeline and connection test action.
  - For local on-demand models, use a longer connection-test timeout (current baseline: `120s`).
  - AI infrastructure diagnostics policy: failed tests/jobs should be written to `Debug Issues`; successful tests/jobs should not create diagnostic noise by default.
- **Phase 2.3 — Orchestration and task pipeline**
  - Integrate AI jobs into `TaskQueue`/`TaskCenter` (queued/running/cancelled/failed).
  - Implement task-to-model routing with optional fallback model.
  - Implement prompt resolution from assistant profile + task context.
- **Phase 2.4 — Minimal UI integration**
  - Implement minimal `AI Assistant` settings page:
    - provider management + API key actions
    - model management + task routing
    - assistant profile editing for system prompts
  - Add basic debug diagnostics for AI tasks in `Debug Issues`.

## Phase 3 — First AI capabilities
- Implement `auto-tag`, single-article summary, and translation.
- Implement AI result persistence and result management actions.
- Support model switching per task and re-run.

## Phase 4 — Stabilization and polish
- Improve retry/timeout behavior.
- Improve diagnostics (`Debug Issues`) for AI failures.
- Tune UX copy, reduce configuration friction, and validate performance.

## Feed Sync Operational Notes (rate limiting)
- For feed hosts returning HTTP `429` (rate limit), apply a host-level temporary cooldown before next fetch attempts (current baseline: `4 hours`).
- Keep feed-level failures diagnostic-first in `Debug Issues`; avoid user popup alerts for these background sync failures.
- Prefer implementing proper conditional requests (`If-Modified-Since` / `If-None-Match`) in a later iteration to reduce repeated payload fetches and lower rate-limit risk.

---

## 7. Acceptance Criteria

## 7.1 Pre-S3 theme acceptance
- Reader has `Light`, `Dark`, and three paper-like built-in presets.
- `Auto` mode follows system dark mode switching correctly.
- Basic font and layout customization is persisted and applied reliably.

## 7.2 Stage 3 AI acceptance
- Multiple provider/model profiles are supported locally.
- Assistant/agent profiles (with system prompts) are configurable locally.
- Task-specific model routing works for tagging/summary/translation.
- AI tasks run via `TaskQueue` with cancellation and progress behavior.
- AI outputs are stored locally and can be re-run or deleted.
- Configuration UI remains simple for first-time use.
- API keys are stored in `Keychain` only; database and logs contain references/redacted values only.
- Reader detail + summary split layout remains stable when switching entry and `Reader/Web/Dual` modes (no unexpected summary pane resize).

---

## 8. Out of Scope for Stage 3
- Account/login system
- Team/cloud-synced AI configuration
- Full multi-article digest pipeline (can start in Stage 4/5)
- FTS-based semantic retrieval integration
- Cross-app/shared-group keychain sharing

## 9. Risks and Mitigations
- UX complexity risk:
  - Mitigate with progressive disclosure and strong defaults.
- Provider variability risk:
  - Mitigate with profile validation and explicit capability indicators.
- Cost/performance risk:
  - Mitigate with task-specific model routing and local small-model support.
- Reliability risk for long responses:
  - Mitigate with streaming, cancellation, and fallback retries.

## 10. Development Test Profile Memo (Local)

Use the following profile as the baseline for Stage 3 local integration testing:

- `baseURL = "http://localhost:5810/v1"`
- `apiKey = "local"`
- `model = "qwen3"`
- `thinkingModel = "qwen3-thinking"`

Notes:
- For local model gateways, API key can be any non-empty string.
- This profile is intended for local development and validation only.
- Production/provider-specific profiles should use real endpoint and credential settings.

---

## 11. Agent Specs v1 (Implementation Contract)

This section defines the first executable contract for the three initial agents.

## 11.1 Shared agent contract

### Input envelope
- `entryId: Int64`
- `sourceText: String`
- `sourceLanguage: String?` (optional autodetect)
- `targetLanguage: String?` (required by translation/optional by summary)
- `systemPromptOverride: String?` (for test and advanced override)
- `outputMode: String` (task-specific enum)
- `detailLevel: String?` (`short|medium|detailed` where applicable)

### Output envelope
- `taskType: String`
- `entryId: Int64`
- `outputText: String`
- `outputLanguage: String?`
- `outputFormat: String` (plain/bilingual/structured)
- `providerProfileId: Int64`
- `modelProfileId: Int64`
- `durationMs: Int`
- `createdAt: Date`

### Error and diagnostics policy
- Agent failures are recorded in `Debug Issues` with task + provider + model context.
- Agent successes are not recorded in `Debug Issues` by default.

## 11.2 Translation agent v1

### User-configurable parameters
- `targetLanguage` (required)
- `outputMode`:
  - `translationOnly`
  - `bilingualParagraph`

### Output requirements
- `translationOnly`: output translated text only.
- `bilingualParagraph`: output paragraph-aligned source+translation blocks in reading order.

### UI entry points
- Reader detail toolbar action: `Translate`.
- Result appears inline in article-side result panel or replace-preview area.

## 11.3 Single-article summary agent v1

### User-configurable parameters
- `targetLanguage` (optional, default to source language)
- `detailLevel`:
  - `short`
  - `medium`
  - `detailed`

### Output requirements
- `short`: concise key takeaway form.
- `medium`: balanced summary for quick understanding.
- `detailed`: richer structure with major points and context.

### UI entry points
- Reader detail lower `Summary` pane with language/detail controls and `Summary/Abort/Copy/Clear`.
- For entries without persisted summary, controls should use `Agents` settings defaults.
- If the entry has an in-flight run, controls should follow that run's slot parameters until completion.

## 11.4 Batch tagging agent v1 (design-first)

### Stage stance
- Do not implement standalone tagging-only interaction first.
- First define the tag system and reading/filter integration, then enable batch tagging.

### Required preconditions
- Tag model: `id`, `name`, optional `color/group`, optional `confidence`.
- Feed/entry filtering UX by tag.
- Clear user control to accept/edit/remove AI-proposed tags.

### Initial output contract
- `tags: [String]`
- `confidenceByTag: [String: Double]?`
- optional rationale (internal/debug only, not required for default UI)

## 11.5 UX integration principle
- AI actions should be embedded in reading workflows, not isolated as a separate "AI destination".
- Once setup and cold-start complete, AI should feel quiet, fast, and task-oriented.
