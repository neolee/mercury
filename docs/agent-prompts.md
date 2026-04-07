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
- Summary, Translation, and Tagging now all derive final request messages from template render output plus explicit parameters only.
- The remaining open work in this document is no longer prompt ownership cleanup. It is the separately tracked Translation repetition diagnosis recorded at the end of this file.

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

Result:

- Summary no longer invents fallback prompt prose when `systemTemplate` is absent.
- If a Summary template renders no system prompt, the final request omits the system message rather than substituting executor-authored text.
- Invalid built-in Summary templates fail explicitly instead of silently falling back to hardcoded prompt prose.

Source locations:

- `Mercury/Mercury/Resources/Agent/Prompts/summary.default.yaml`
- `Mercury/Mercury/Agent/Summary/AppModel+SummaryExecution.swift`

### 2.4 Tagging

Current state:

- `tagging.default.yaml` defines the prompt.
- `TaggingLLMExecutor.swift` renders system and user prompt strings and passes them directly into `LLMRequest.messages`.
- No render-post prompt mutation was found in the current Tagging path.
- If a Tagging template renders no system prompt, the final request omits the system message rather than substituting executor-authored prompt prose.

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

Status:

- Implemented.
- Summary no longer uses an executor-owned fallback system prompt.
- If `systemTemplate` is absent, the final request omits the system message instead of inventing replacement prose.
- Invalid built-in Summary templates now fail explicitly in tests rather than silently relying on fallback prompt text.
- Full repository validation passed with `./scripts/build` and `./scripts/test` after this step landed.

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

Status:

- Implemented for prompt-ownership governance.
- Summary, Translation, and Tagging now all construct final messages from template render output plus explicit parameters.
- Empty rendered system prompts now produce one-message requests instead of executor-authored fallback prose.
- Repository-standard validation passed with `./scripts/build` and `./scripts/test` after the final re-audit.

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

This section records the final conclusion and product decision for the observed Translation repetition / adhesion issue. Diagnosis is considered complete.

### 4.1 Conclusion

- The issue is a model-prompt compatibility problem between the HY-MT family and Mercury's current built-in contextual Translation prompt, not a bilingual composition, persistence, or retry-merge bug.
- Mercury sends fresh per-segment requests built only from the rendered prompt messages for that segment. There is no hidden multi-turn history and no render-post concatenation of `previousSourceText`.
- llama.cpp-side cache, chat-template, and similar server tuning did not materially change the outcome.
- HY-MT is highly sensitive to the exact wording and structure of contextual translation prompts.
- Mercury's current built-in contextual prompt is unstable for HY-MT. A minimal no-context prompt is stable, but removes useful context.
- The validated Chinese contextual prompt variant is stable across repeated Mercury tests on multiple articles. English contextual variants remained less reliable.
- A quick 7B check did not change the product conclusion.

### 4.2 Product Decision

- Add an agent-level Translation prompt strategy setting with two values: `Standard` and `HY-MT Optimized`.
- Do not auto-detect HY-MT from model names or provider metadata.
- `Standard` keeps the general built-in Translation template.
- `HY-MT Optimized` uses a dedicated built-in Translation template based on the validated Chinese contextual prompt.

### 4.3 Architecture Decision

- Introduce `AgentPromptResolver` alongside `AgentPromptCustomization`.
- `AgentPromptCustomization` continues to own custom-template loading, validation, version matching, and fallback notices.
- `AgentPromptResolver` selects the effective built-in template from agent type and agent prompt strategy.
- Summary and Tagging resolve to their default built-ins. Translation resolves between the standard and HY-MT-optimized built-ins.
- A valid custom template remains the highest-priority prompt source and is never overridden by built-in strategy routing.

### 4.4 Status

- Root cause and product direction are considered settled.
- The remaining work is implementation of the new Translation prompt strategy and shared prompt resolver.
