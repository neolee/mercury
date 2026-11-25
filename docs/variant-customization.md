# Variant-Scoped Prompt Customization

Status: In Progress (Step 1 and Step 2 implemented; Step 3 pending)
Last updated: 2026-11-25

## 1. Purpose

Translation has two built-in prompt templates: a general template and a HY-MT-optimized template. Custom prompt overrides must preserve the same two-track separation. A custom Standard prompt must not silently replace the HY-MT template, and a custom HY-MT prompt must not silently replace the Standard template.

This document defines the desired identity model, resolution rules, migration policy, and implementation plan. No implementation should start before this proposal is reviewed and approved.

## 2. Current State

- Built-in translation prompts are already two-track:
  - `translation.default.yaml`, template ID `translation.default`
  - `translation.hy-mt.yaml`, template ID `translation.hy-mt`
  - `AgentPromptResolutionContext.translation(strategy:)` selects the built-in template according to the active strategy.
- Custom translation prompts are single-track:
  - Every translation strategy resolves the same sandbox file, `translation.yaml`.
  - That file is always parsed as template ID `translation.default`, regardless of the active strategy.
  - Seeding the file from the HY-MT built-in rewrites its `id` field to `translation.default`.
- Version matching compares the custom file against the built-in template of the currently active strategy. Both translation built-ins are currently `v5`, so one shared custom file passes validation in both modes. If either built-in receives a version bump, the same custom file can be accepted in one mode and rejected in the other.
- A custom file created from one strategy can therefore be used silently by the other strategy. The two templates have different contracts, including `systemTemplate` presence and language-name placeholders, so this produces incorrect prompts without a hard failure.
- `AgentPromptResolver.swift` currently mixes template identity with loading behavior. It duplicates template ID/name selection, hardcodes `translation.hy-mt`, contains a second loading and version-validation path, and rewrites seed content with a regular expression.
- Existing tests and documentation encode the single shared override as expected behavior. Those statements are implementation drift and must be replaced by the design in this document.

## 3. Goals

- Built-in and custom prompts are two parallel tracks for every agent task type.
- Each translation variant has its own built-in prompt, custom override file, version validation, and fallback behavior.
- Template identity is represented by one immutable descriptor with no duplicated template ID, file name, or variant routing data.
- Template IDs and canonical custom file names are derived from the descriptor identity.
- One resolution and loading path owns template selection, custom-file loading, version validation, and built-in fallback.
- The settings UI keeps its existing layout and controls; the prompt row label changes from `Prompt Strategy` to `Prompt Variant` for terminology consistency.
- No database migration and no built-in prompt content change are required.

## 4. Non-Goals

- No automatic HY-MT detection from model names or provider metadata. Prompt variant remains an explicit user choice.
- No prompt wording or prompt-version changes for the existing built-in templates.
- No new settings UI, buttons, or explanatory panels.
- No legacy custom-file compatibility layer.
- No database schema or translation-record migration.

## 5. Key Design Decisions

### 5.1 Variant Is the Standard Term

A prompt template is identified by:

- `agent`: existing `AgentTaskType` value (`summary`, `translation`, `tagging`).
- `variant`: a model-family-oriented prompt variant.

`variant` is the standard term for both template identity and the translation prompt setting. There is no separate `TranslationPromptStrategy` type. The persisted translation setting stores an `AgentPromptVariant` directly.

`AgentPromptVariant` is a String-backed enum so the Swift case name and the stable identifier are independent:

```swift
enum AgentPromptVariant: String, Sendable, Hashable, CaseIterable {
    case `default` = "default"
    case hyMT = "hy-mt"
}
```

Rules:

- Template IDs use `variant.rawValue`, never the enum case name rendered as a string.
- `String(describing:)` and string interpolation of the enum value produce `"hyMT"` and must not be used for IDs or file names.
- Variant raw values are stable persisted identifiers. They must be lowercase, filename-safe, and must not contain `.`, `/`, or whitespace.
- `AgentTaskType.rawValue` is also part of the template ID contract. Its raw values must remain `summary`, `translation`, and `tagging`.
- Variant raw values are not display names. The localized translation label for `default` is `Standard`, and for `hyMT` it is `HY-MT Optimized`.
- Future model-specific variants should be added as new variant values, for example `hy-mt2`, instead of mutating an existing variant.

### 5.2 Derived Template ID and File Names

For every descriptor:

- `templateID = "\(agent.rawValue).\(variant.rawValue)"`
- `builtInTemplateName = templateID`
- `customTemplateFileName = "\(templateID).yaml"`

This reproduces the existing template IDs exactly:

| Agent | Variant | Template ID | Built-in file | Canonical custom file |
|---|---|---|---|---|
| summary | default | `summary.default` | `summary.default.yaml` | `summary.default.yaml` |
| translation | default | `translation.default` | `translation.default.yaml` | `translation.default.yaml` |
| translation | hy-mt | `translation.hy-mt` | `translation.hy-mt.yaml` | `translation.hy-mt.yaml` |
| tagging | default | `tagging.default` | `tagging.default.yaml` | `tagging.default.yaml` |

The canonical custom file name is always the built-in file name. No mapping table, ID rewriting, or variant-specific file-name branch is allowed in production code.

### 5.3 Descriptor and Static Catalog

Rename `AgentPromptCustomizationConfig` to `AgentPromptTemplateDescriptor`.

The descriptor is immutable and contains only:

- `agent: AgentTaskType`
- `variant: AgentPromptVariant`
- Small presentation metadata needed for fallback messages and debug titles

Everything else is computed:

- `templateID`
- `builtInTemplateName`
- `customTemplateFileName`
- `customization`

Descriptors are constructed only by the static catalog:

| Catalog entry | Agent | Variant |
|---|---|---|
| `.summaryDefault` | summary | default |
| `.translationDefault` | translation | default |
| `.translationHYMT` | translation | hy-mt |
| `.taggingDefault` | tagging | default |

The catalog also provides:

- `translation(for: AgentPromptVariant)` as the only variant-to-descriptor mapping.
- `translationVariants` as the ordered list of variants selectable for translation.
- `all` as the complete descriptor list for tests and shared validation.

Production code must not construct arbitrary descriptors outside the catalog. Invalid combinations such as `summary + hyMT` are prevented by catalog-only construction and contract tests.

Callers pass descriptors directly. There is no `AgentPromptResolutionContext` and no per-agent resolution case:

- Summary passes `.summaryDefault`.
- Tagging passes `.taggingDefault`.
- Translation maps its persisted `AgentPromptVariant` through `.translation(for:)` at the settings or execution boundary.

This keeps summary, translation, and tagging on one uniform resolution path. The ambiguous `.translation` descriptor and the `builtInTemplateID` / `builtInTemplateName` computed properties are removed.

### 5.4 One Loading and Validation Path

- `TemplateCustomization` remains the shared engine for file lookup, YAML parsing, version comparison, and built-in fallback.
- `AgentPromptCustomization` provides the agent-facing load and seed helpers on top of the shared engine.
- `AgentPromptResolver` remains a thin facade that accepts a descriptor and delegates loading and seeding. It must not own a second loading or version-validation implementation.
- Remove `AgentPromptResolutionContext` entirely.
- Remove the duplicate `AgentPromptResolutionResult`; use the shared template-load result type.
- Remove the unused `AppModel.loadPromptTemplate`.
- Remove `normalizedCustomTemplateContent`, `resolvedBuiltInTemplateURL`, and any seed-time ID rewriting.
- Remove the now-unused built-in content transform parameter from `TemplateCustomization`.
- Derive `AgentPromptTemplateStore.builtInFileNames` from the descriptor catalog, including the `.yaml` and `.yml` variants, so the built-in file list has one source of truth.
- Update the translation execution default `loadedTemplateId` to use the descriptor catalog instead of the removed `.translation` descriptor.

Custom template files are copied exactly from their built-in counterpart. If a custom file's declared `id` does not match its descriptor's `templateID`, it is invalid and falls back to the same descriptor's built-in template.

### 5.5 Fallback Projection Carries the Active Variant

`TranslationRunNotice.promptTemplateFallback` must carry the translation variant that the run actually used:

```text
promptTemplateFallback(variant: AgentPromptVariant, reason: TemplateCustomizationFallbackReason)
```

The projection layer resolves the descriptor through `AgentPromptTemplateDescriptor.translation(for: variant)` and asks that descriptor for the fallback message and debug title. It must not:

- read the current user setting, which may have changed since the run started;
- switch on hardcoded variant strings;
- reference a fixed `.translation` descriptor.

User-visible fallback text distinguishes HY-MT from Standard by including the HY-MT variant label; Standard uses the base Translation label. Debug issue titles are also variant-specific and remain unlocalized.

### 5.6 UI Stays Unchanged

- The settings page keeps a single `custom prompts` action.
- The translation picker row is labeled `Prompt Variant`, selects an `AgentPromptVariant`, and uses the translation labels `Standard` and `HY-MT Optimized`.
- The action passes `.translation(for: translationPromptVariant)` as the descriptor.
- It opens the canonical custom file for the active descriptor.
- It creates the canonical file from the built-in only when the file does not exist.
- It never overwrites an existing custom file.
- No new rows, buttons, captions, or layout changes are introduced.
- The only user-visible text changes are the `Prompt Variant` row label and variant-specific fallback messaging; neither changes the settings layout or controls.

### 5.7 Legacy Custom Files

Legacy custom-file compatibility is intentionally dropped.

- `summary.yaml`, `tagging.yaml`, and `translation.yaml` are no longer read.
- No alias list, candidate-file search, or precedence rule is implemented.
- `translation.yaml` is never mapped to the HY-MT variant.
- Migration is documented in release notes and `CUSTOM.md`.
- Users must rename old files to the canonical names. HY-MT content previously stored in `translation.yaml` also requires the `id` field to change to `translation.hy-mt`.

This keeps the invariant simple: one descriptor has exactly one canonical custom file name.

## 6. Compatibility and Migration

- Built-in template IDs, built-in file names, and built-in YAML content remain unchanged.
- No prompt version bump is required.
- Existing translation records remain compatible. Changing a prompt or variant does not automatically invalidate stored translations; users must clear and retranslate to see prompt changes. This is existing behavior.
- The translation prompt setting moves from `Agent.Translation.PromptStrategy` to `Agent.Translation.PromptVariant`.
- Old setting values map as follows:

| Old key and value | New key and value |
|---|---|
| `Agent.Translation.PromptStrategy` = `standard` | `Agent.Translation.PromptVariant` = `default` |
| `Agent.Translation.PromptStrategy` = `hy_mt_optimized` | `Agent.Translation.PromptVariant` = `hy-mt` |

The loader reads the new key first, falls back to the legacy key when needed, and writes only the new key on save.
- Old custom files are ignored. The following rename table must appear in release notes and `CUSTOM.md`:

| Old file | New file | Additional action |
|---|---|---|
| `summary.yaml` | `summary.default.yaml` | None |
| `tagging.yaml` | `tagging.default.yaml` | None |
| `translation.yaml` with Standard content | `translation.default.yaml` | None |
| `translation.yaml` with HY-MT content | `translation.hy-mt.yaml` | Change `id:` to `translation.hy-mt` |

## 7. Implementation Plan

The work should be delivered in three reviewable steps. Each step must leave the build and tests green.

### Step 1: Introduce Descriptor Identity and Canonical Custom Files

Changes:

- Add `AgentPromptVariant` with stable raw values.
- Rename `AgentPromptCustomizationConfig` to `AgentPromptTemplateDescriptor`.
- Add the static descriptor catalog and `translation(for:)` mapping.
- Derive template ID, built-in name, and canonical custom file name.
- Update `AgentPromptResolutionContext`, resolver call sites, translation execution defaults, and tests.
- Remove the ambiguous `.translation` descriptor and hardcoded `translation.hy-mt` references.
- Switch custom seeding and loading to canonical file names.
- Remove legacy file lookup, seed-time ID rewriting, `normalizedCustomTemplateContent`, and `resolvedBuiltInTemplateURL`.
- Add the active variant to `TranslationRunNotice.promptTemplateFallback` and resolve fallback messages and debug titles through the descriptor catalog.
- Add or update localization entries for variant-specific fallback text using the existing `Localizable.xcstrings` workflow. Do not edit extraction metadata manually.

Verification:

- `./scripts/build` passes without warnings.
- Descriptor contract tests assert the generated template IDs, built-in names, custom file names, and task types for all four catalog entries.
- Resolver tests assert:
  - Standard seeds `translation.default.yaml` with `id: translation.default`.
  - HY-MT seeds `translation.hy-mt.yaml` with `id: translation.hy-mt`.
  - Existing custom files are never overwritten.
  - Standard and HY-MT custom files do not affect each other.
  - Legacy `translation.yaml` is ignored.
- Fallback and projection tests assert that Standard and HY-MT failures each produce their own message and debug title.
- Search production sources for `translation.yaml`, hardcoded `"translation.hy-mt"`, and ambiguous `.translation` descriptor references and confirm only intentional migration documentation remains.
- `./scripts/test` passes.

### Step 2: Remove Context, Migrate Settings, and Consolidate Loading

Changes:

- Delete `AgentPromptResolutionContext` and pass `AgentPromptTemplateDescriptor` directly through resolver, AppModel helpers, settings, and execution.
- Replace `TranslationPromptStrategy` with `AgentPromptVariant` in the translation settings layer, including the picker state, agent defaults, configuration snapshot, execution, and fallback notice.
- Add the settings migration from `Agent.Translation.PromptStrategy` to `Agent.Translation.PromptVariant`, with legacy value mapping.
- Make `AgentPromptResolver` a thin descriptor-based facade; remove its duplicate loading/version path.
- Make `AgentPromptCustomization.loadTemplate` return the shared template-load result type.
- Remove `AgentPromptResolutionResult` and the unused `AppModel.loadPromptTemplate`.
- Remove the unused built-in content transform parameter from `TemplateCustomization`.
- Derive `AgentPromptTemplateStore.builtInFileNames` from the descriptor catalog.
- Update tests affected by the consolidation and add settings migration coverage.

Verification:

- `./scripts/build` passes without warnings.
- `./scripts/test` passes.
- No production or test source references `AgentPromptResolutionContext` or `TranslationPromptStrategy`. The only reference to the old prompt strategy settings key is the migration fallback.
- Built-in template loading still finds all four resources through the catalog-derived file list.
- Settings tests cover:
  - New `AgentPromptVariant` values persist and reload.
  - Legacy `standard` and `hy_mt_optimized` values migrate to `default` and `hy-mt`.
  - New writes use `Agent.Translation.PromptVariant`.
- Fallback tests remain green and assert:
  - An invalid or version-mismatched Standard custom file falls back to the Standard built-in only.
  - An invalid or version-mismatched HY-MT custom file falls back to the HY-MT built-in only.
  - Projection messages identify the correct variant.
- Search production sources for removed symbols and confirm no duplicate loader or hardcoded translation routing remains.
- Manual check: invalidate each custom file in turn, run both translation modes, and confirm only the matching mode shows a fallback notice while the other mode still uses its own prompt.

### Step 3: Migration Documentation and Final Validation

Changes:

- Update `CUSTOM.md` with canonical file names and the rename table.
- Update `docs/agent-prompts.md` so the prompt-governance rule states that custom overrides are highest priority only within their own descriptor.
- Update `docs/features/translate-agent.md` settings and prompt-file references.
- Update the prompt-template contract in `AGENTS.md` to record the one-descriptor/one-custom-file rule.
- Update README or release notes wherever the customization workflow is described.
- State explicitly that old custom files are ignored and manual rename is required.

Verification:

- Documentation review confirms the rename table and the two-track rule are unambiguous.
- Search repository documentation for old custom file names and confirm they appear only in migration notes.
- `./scripts/build` and `./scripts/test` pass without warnings.
- Manual check with a clean Application Support directory:
  - Standard `custom prompts` creates `translation.default.yaml`.
  - HY-MT `custom prompts` creates `translation.hy-mt.yaml`.
  - Editing one file changes only its variant.
  - Deleting one file reverts only its variant.
  - Old files are not read.

## 8. Acceptance Criteria

- All four descriptors generate the exact existing built-in template IDs.
- Built-in and custom prompts are two independent tracks for every agent.
- Translation Standard and HY-MT use different custom files and different version checks.
- Custom file seeding is an exact copy of the matching built-in template.
- No code rewrites a custom template's `id` or maps custom files across variants.
- Fallback behavior and user-visible messages are variant-specific.
- The settings UI keeps its existing layout and controls; only the prompt row label changes to `Prompt Variant` for terminology consistency.
- No `AgentPromptResolutionContext` or `TranslationPromptStrategy` type remains.
- The translation prompt setting persists `AgentPromptVariant` and migrates legacy `standard`/`hy_mt_optimized` values.
- No database migration and no built-in prompt version bump are included.
- `./scripts/build` and `./scripts/test` pass without compiler errors or warnings.
