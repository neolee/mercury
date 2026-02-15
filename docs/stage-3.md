# Stage 3 — AI Foundation + Reader Theme Customization (Plan)

> Date: 2026-02-15
> Last updated: 2026-02-16
> Scope: Stage 3 AI foundation, with one Pre-S3 UX enhancement for reader themes

This document defines the next major implementation phase after Stage 1 and Stage 2 closure.

Stage 3 has two parts:
1. A **Pre-S3 task** to improve the reading experience with customizable reader themes.
2. The **Stage 3 AI foundation** for local-first, no-login, multi-provider and multi-model AI workflows.

Current status:
- Pre-S3 reader theme work is complete.
- Active implementation should start from Stage 3 AI foundation (Phase 2 in this document).

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

## 5. AI Configuration UI Design (Simple but Powerful)

## 5.1 Design goals
- Keep default path minimal and usable.
- Expose advanced controls progressively.
- Make model routing understandable at a glance.

## 5.2 Proposed structure
A compact `AI Settings` section with three levels:

1. **Quick Setup**
- Enable/disable AI
- Choose active provider profile
- Enter/update/remove API key (stored in `Keychain`)
- Validate connectivity

2. **Model Routing**
- `Tagging model`
- `Summary model`
- `Translation model`
- Optional fallback toggle per task

3. **Assistants / Agents**
- Configure built-in assistant profiles by task
- Edit/preview system prompt templates
- Bind assistant to routed model (or optional override)

4. **Advanced (collapsible)**
- streaming behavior preferences
- timeout/retry policy
- optional prompt style profile (concise, balanced)

## 5.3 Simplicity principles
- Keep required fields minimal for first-time setup.
- Offer presets for common local gateways.
- Use clear validation and inline error hints.
- Avoid forcing users to understand all provider details before first successful run.

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
