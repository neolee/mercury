# Stage 3 — AI Foundation + Reader Theme Customization (Plan)

> Date: 2026-02-15
> Last updated: 2026-02-15
> Scope: Stage 3 AI foundation, with one Pre-S3 UX enhancement for reader themes

This document defines the next major implementation phase after Stage 1 and Stage 2 closure.

Stage 3 has two parts:
1. A **Pre-S3 task** to improve the reading experience with customizable reader themes.
2. The **Stage 3 AI foundation** for local-first, no-login, multi-provider and multi-model AI workflows.

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

## 4.2 Task orchestration and execution
- Reuse `TaskQueue` / `TaskCenter` for all AI jobs.
- AI jobs must be cancellable, progress-reporting, and debuggable.
- Avoid ad-hoc parallel execution paths in UI.

## 4.3 Data model additions (local)
Recommended new entities:
- `AIProviderProfile`
  - endpoint/base URL
  - auth mode reference (not embedding secrets in app binaries)
  - enabled state
- `AIModelProfile`
  - model name
  - provider profile reference
  - capability flags (tagging/summary/translation)
- `AITaskRouting`
  - mapping from task type to preferred model profile
  - optional fallback model profile
- `AIResult`
  - `entryId`, task type, output payload, language (if translation), model metadata, created time

All AI-related data should remain local-first.

## 4.4 Streaming and rendering
- Support `SSE` streaming for progressive updates.
- UI should display incremental output for long responses.
- Persist final stable output only after completion.

## 4.5 Security and privacy
- Do not hardcode API keys in client builds.
- For production, prefer local proxy/gateway handling secrets.
- Provide clear user messaging about what text is sent to selected AI endpoints.

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
- Validate connectivity

2. **Model Routing**
- `Tagging model`
- `Summary model`
- `Translation model`
- Optional fallback toggle per task

3. **Advanced (collapsible)**
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
- Implement `LLMProvider` abstraction and first provider adapter.
- Implement provider/model profile storage and validation.
- Implement task routing and orchestration through `TaskQueue`.
- Implement `SSE` streaming pipeline to UI.

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
- Task-specific model routing works for tagging/summary/translation.
- AI tasks run via `TaskQueue` with cancellation and progress behavior.
- AI outputs are stored locally and can be re-run or deleted.
- Configuration UI remains simple for first-time use.

---

## 8. Out of Scope for Stage 3
- Account/login system
- Team/cloud-synced AI configuration
- Full multi-article digest pipeline (can start in Stage 4/5)
- FTS-based semantic retrieval integration

## 9. Risks and Mitigations
- UX complexity risk:
  - Mitigate with progressive disclosure and strong defaults.
- Provider variability risk:
  - Mitigate with profile validation and explicit capability indicators.
- Cost/performance risk:
  - Mitigate with task-specific model routing and local small-model support.
- Reliability risk for long responses:
  - Mitigate with streaming, cancellation, and fallback retries.
