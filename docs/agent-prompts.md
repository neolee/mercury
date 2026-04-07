# Agent Prompt Governance Audit

This document defines the prompt-governance baseline for Mercury agent tasks. It confirms the current implementation state, identifies the places that do not satisfy the prompt ownership rule, and records the implementation plan for fixing those issues before any further prompt optimization work.

---

## 1. Core Principles

- Final model-facing prompt text and message content must be determined by the prompt template, explicit render parameters, and shared template semantics only.
- Execution code may choose parameter values, but it must not add, rewrite, prepend, or append prompt prose after template rendering.
- Fallback prompt text is still prompt content, so it must not be owned by an individual executor.
- Optional prompt features, such as Translation previous-context guidance, must be expressed through template capabilities rather than executor-side string concatenation.
- Reading the template and the declared render parameters must be sufficient to reconstruct the final messages sent to the model.

Confirmed design decisions:

- Agent prompt templates will reuse Digest-style conditional-section syntax: `{{#name}}...{{/name}}`.
- Agent prompt templates will support conditional sections only. Nested sections and repeated sections are out of scope.
- Shared template-processing logic should be extracted as far as practical into common code, while Agent and Digest remain separate template families with different schema and policy.
- `systemTemplate` is a supported but optional capability. Executors must not invent fallback prompt prose when it is absent.
- Invalid or version-mismatched custom templates continue to fall back to the built-in template with user-visible notice and debug logging.
- Invalid built-in templates are program bugs and must fail fast with explicit error reporting instead of silently switching to hardcoded fallback prompt text.
- Prompt/message construction should become directly testable through a lightweight builder or equivalent inspection seam rather than heavy runtime instrumentation.

---

## 2. Current State

### 2.1 Shared prompt-template infrastructure

Current shared infrastructure already provides these capabilities:

- `AgentPromptCustomization` loads built-in or custom templates and handles invalid-template and version-mismatch fallback.
- `AgentPromptTemplateStore` parses YAML templates and exposes `render(parameters:)` and `renderSystem(parameters:)`.
- `TemplateProcessingCore` provides placeholder extraction, validation, and direct placeholder replacement.
- The existing template-customization flow already rejects version-mismatched custom templates and falls back to the built-in template.

Current gap:

- Shared conditional-section support and message-construction seams are now in place.
- The remaining prompt-governance gap is executor-owned fallback prompt prose in Summary, plus final alignment work across all agent executors.

Relevant files:

- `Mercury/Mercury/Agent/Shared/AgentPromptCustomization.swift`
- `Mercury/Mercury/Agent/Shared/AgentPromptTemplateStore.swift`
- `Mercury/Mercury/Core/Shared/TemplateProcessingCore.swift`
- `Mercury/Mercury/Digest/Shared/DigestTemplateStore.swift`

### 2.2 Translation

Current state:

- `translation.default.yaml` defines the base system and user prompt.
- `AppModel+TranslationExecution+Support.swift` renders the template.
- `previousSourceText` is now passed only as explicit optional render data.
- The built-in Translation template now owns the optional previous-context block through a conditional section.

Result:

- Translation no longer rewrites the rendered user prompt after template rendering.
- The final Translation user message is now fully template-controlled.
- The built-in Translation prompt version is now `v4`.

Source locations:

- `Mercury/Mercury/Resources/Agent/Prompts/translation.default.yaml`
- `Mercury/Mercury/Agent/Translation/AppModel+TranslationExecution+Support.swift`
- `Mercury/Mercury/Agent/Translation/AppModel+TranslationExecution.swift`
- `Mercury/Mercury/Agent/Translation/AppModel+TranslationExecution+PerSegment.swift`

### 2.3 Summary

Current state:

- `summary.default.yaml` defines the normal built-in prompt.
- `AppModel+SummaryExecution.swift` uses the rendered system prompt when present.
- If `renderSystem(parameters:)` returns `nil`, execution currently falls back to a hardcoded executor-owned prompt string.

Problem:

- This violates the core principles because fallback prompt content is owned by executor code.
- `systemTemplate` itself is not globally required, so the problem is not that Summary lacks a mandatory field. The problem is that the executor silently invents prompt prose when the rendered system prompt is absent.
- For the built-in Summary template path, this extra fallback is unnecessary. If the built-in template is broken, execution should fail instead of silently switching to hardcoded prompt prose.

Source locations:

- `Mercury/Mercury/Resources/Agent/Prompts/summary.default.yaml`
- `Mercury/Mercury/Agent/Summary/AppModel+SummaryExecution.swift`

### 2.4 Tagging

Current state:

- `tagging.default.yaml` defines the prompt.
- `TaggingLLMExecutor.swift` renders system and user prompt strings and passes them directly into `LLMRequest.messages`.
- No render-post prompt mutation was found in the current Tagging path.

Remaining issue:

- Tagging is closer to the target state, but executor behavior when `systemTemplate` is absent should still be aligned with the shared rule that executors must not author fallback prompt prose.

Source locations:

- `Mercury/Mercury/Resources/Agent/Prompts/tagging.default.yaml`
- `Mercury/Mercury/Agent/Tagging/TaggingLLMExecutor.swift`

---

## 3. Remediation Plan

### 3.1 Shared capability and test foundation

Status:

- Implemented.
- Shared section parsing/rendering now lives in common code and is reused by both Agent prompts and Digest templates with family-specific policy.
- Agent prompt templates now support Digest-style conditional sections and explicitly reject nested or repeated sections.
- Summary, Translation, and Tagging now expose lightweight final-message construction seams so tests can assert the exact rendered messages.
- Full repository validation passed with `./scripts/build` and `./scripts/test` after this step landed.

Changes:

- Add focused tests for Summary, Translation, and Tagging prompt construction so final `LLMRequest.messages` behavior is observable and frozen.
- Extract shared template-processing logic as far as practical into common code, reusing or adapting the existing Digest section-processing approach instead of adding agent-specific string assembly.
- Keep Agent and Digest as separate template families with separate schema and render APIs, and express the differences through policy rather than duplicate parsing logic.
- Add shared support for conditional sections in agent prompt templates using the Digest-style syntax, but limit agent prompts to conditional sections only, with no nesting and no repeated sections.
- Keep placeholder classification and validation rules explicit and test-covered.
- Introduce a lightweight builder or equivalent inspection seam so tests can assert final prompt messages directly.

Automated validation:

- Unit tests cover final prompt construction for all three agents.
- Unit tests cover optional-section rendering for agent prompt templates.
- Unit tests verify that nested or repeated sections are rejected for agent prompt templates.
- Unit tests fail if prompt prose is still changed outside the template layer.

Manual validation:

- Reading a template plus its render parameters is enough to reconstruct the final messages sent to the model.
- No executor helper remains responsible for hidden prompt prose assembly.
- Shared template code is centralized, while Agent and Digest still retain clear family-specific boundaries.

### 3.2 Translation cleanup

Status:

- Implemented.
- Translation no longer performs render-post prompt mutation.
- `previousSourceText` is passed only as optional render data and consumed by a conditional section in `translation.default.yaml`.
- Full repository validation passed with `./scripts/test` after this step landed.

Changes:

- Remove render-post prompt mutation from Translation.
- Pass `previousSourceText` only as explicit optional render data.
- Update `translation.default.yaml` so previous context, if used, is fully template-controlled.
- Keep previous-context support, but make it available through template semantics rather than executor-authored prompt prose.

Automated validation:

- Translation tests verify first-segment and non-first-segment prompt construction.
- Translation tests verify that the final user message is derived only from template content plus render parameters.
- No Translation executor test depends on a render-post string concatenation helper.

Manual validation:

- Previous-context support still works.
- The final Translation user prompt can be reconstructed from the template without inspecting executor-side string rewriting.
- The path is ready for later anti-adhesion prompt experiments without hidden prompt factors.

### 3.3 Summary cleanup

Changes:

- Remove the hardcoded Summary fallback system prompt from executor ownership.
- Treat a broken built-in Summary template as a failure condition instead of silently substituting hardcoded prompt text.
- Respect `systemTemplate` as an optional capability, but do not allow Summary executor code to invent replacement prompt prose.
- Keep custom-template fallback behavior unchanged: invalid or version-mismatched custom templates still fall back to the built-in template.

Automated validation:

- Summary tests verify normal prompt construction.
- Summary tests verify that invalid built-in template behavior fails explicitly instead of falling back to executor-authored prompt prose.
- Summary tests verify that invalid or version-mismatched custom templates still fall back to the built-in template.

Manual validation:

- Summary executor no longer owns prompt wording outside the template layer.
- Failure behavior is explicit and easier to reason about than the current hidden fallback path.

### 3.4 Cleanup and finish work

Changes:

- Align Summary, Translation, and Tagging with the shared rule that executors do not author fallback prompt prose when `systemTemplate` is absent.
- Re-audit the resulting implementation against the core principles.
- Update this document after the cleanup lands so it reflects the new steady state.
- After governance cleanup is complete, start Translation anti-adhesion optimization work under the new prompt boundary.

Automated validation:

- Shared and per-agent tests cover conditional-section policy, custom-template fallback behavior, and the absence of render-post prompt mutation.
- Regression tests confirm that no executor performs render-post prompt mutation.

Manual validation:

- The document, implementation, and tests all describe the same rules.
- Translation prompt experiments can be evaluated cleanly because prompt ownership is no longer split between templates and hidden executor code.

---

## 4. Translation Repetition Diagnosis

This section records the current diagnosis status for the observed Translation result repetition issue. It is intentionally scoped as a diagnostic ledger only. The issue is not part of steps 3.3 or 3.4 and should be handled as a separate follow-up after the current governance cleanup is complete.

### 4.1 Confirmed facts

- Custom Translation templates are confirmed to be active when structurally valid and version-matched. The observed run was not a built-in-template fallback case.
- Translation prompt ownership has already been cleaned up in step 3.2. Mercury no longer performs render-post concatenation of `previousSourceText` into the final user prompt.
- Translation requests are currently sent as fresh single-turn chat requests containing only the rendered `system` and `user` messages for that segment. No prior assistant messages or multi-turn conversation history are appended by Mercury.
- `previousSourceText` may still be computed and passed as optional render data, but if the active template removes the `{{#previousSourceText}}...{{/previousSourceText}}` block, that context is not rendered into the final prompt text.
- The observed repeated-result symptom is not an exact duplicated insertion of the same translated block. The repeated content is similar but not textually identical.
- Because the repeated content is not an exact duplicate, a simple late-stage bilingual block insertion bug is currently considered less likely than earlier hypotheses.
- Current Translation segment extraction collects each `p`, `ul`, or `ol` element independently from rendered HTML. Current Translation bilingual composition inserts one rendered translation block per segment and does not intentionally rewrite translated text content beyond display normalization.

### 4.2 Working hypotheses still open

- The model or local inference engine may be producing semantically repetitive output for later segments even when no previous-context block is present in the prompt.
- The rendered article HTML may contain adjacent source segments whose text already overlaps semantically or structurally, making the downstream translation output appear repetitive even without prompt leakage.
- There may be a lower-probability issue in an intermediate stage such as retry merge, persistence reuse, or another non-prompt execution path, but there is no confirming evidence for that path at this time.

### 4.3 What is not yet confirmed

- The raw `sourceText` values for the problematic neighboring segments have not yet been captured and compared.
- The exact final rendered user prompt for the problematic segment has not yet been captured from a live failing run.
- The raw model response for the problematic segment has not yet been captured before bilingual composition.
- It has not yet been determined whether the repetition is introduced by the model output itself or already latent in the extracted source segments.

### 4.4 Deferred follow-up plan

- Finish steps 3.3 and 3.4 first so prompt-governance cleanup is complete and the Translation path remains easier to reason about.
- After that cleanup lands, add lightweight diagnostic instrumentation for Translation runs that can capture, for selected problematic segments, the source segment text, final rendered prompt, and raw model response.
- Use that evidence to classify the issue as one of: model/inference behavior, upstream rendered-HTML or segment-shape overlap, or a residual execution/persistence bug.
