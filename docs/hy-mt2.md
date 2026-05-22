# HY-MT2 Translation Prompt Plan

This note records the planned Mercury changes for Tencent Hy-MT2, based on the
official Hy-MT2 1.8B GGUF model card:

- <https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF>

## Current State

Mercury has a dedicated Translation prompt strategy named `HY-MT Optimized`.
It currently resolves to `Resources/Agent/Prompts/translation.hy-mt.yaml`.

The current template exists because HY-MT1.5 behaved better with a short
Chinese contextual prompt than with Mercury's standard English Translation
template. It has no `systemTemplate`, which should stay true for Hy-MT2 because
the official model card says the 1.8B and 7B models have no default
`system_prompt`.

The current target-language placeholder is `targetLanguageDisplayName`.
That value is a UI-style display string generated from `Locale.current`; it can
include the language code and can vary with the user's system language. It is
not a stable model-facing English language name.

## Hy-MT2 Official Prompt Signals

The Hy-MT2 model card now provides Chinese and English prompt examples for the
same translation tasks. It explicitly says:

- Use full language names.
- Use Chinese names in Chinese prompts.
- Use English names in English prompts.
- The default English translation instruction is supported.

The model card no longer presents the old HY-MT1.5-style contextual translation
example. Instead, it includes `Structured Data 2`, which uses a background block
and a source-text block:

- `[Background Information]`
- `[Source Text]`

That example is useful for Mercury because Translation sends each segment as a
fresh request, optionally with the previous segment as local context. Mercury's
context is narrower than generic background information: it is the previous
paragraph or previous source segment from the same article, and it must not be
translated.

## Prompt Direction

Use an English HY-MT template for Hy-MT2.

Reasons:

- Mercury's other built-in agent templates are English, so this removes the
  HY-MT-specific Chinese prompt exception that was only needed for HY-MT1.5.
- Hy-MT2's official examples include English prompts as first-class examples.
- Keeping one English template avoids maintaining a separate Chinese-language
  model-facing language-name table.
- The `HY-MT Optimized` strategy should differ from `Standard` by message shape
  and HY-MT-specific wording, not by prompt language.

Keep the template user-only, with no `systemTemplate`.

## Proposed Template

The Hy-MT2 template should use a model-facing English language-name parameter,
not Mercury's UI-facing `targetLanguageDisplayName`.

```yaml
id: translation.hy-mt
version: v5
taskType: translation
requiredPlaceholders:
  - targetLanguageEnglishName
  - sourceText
optionalPlaceholders:
  - previousSourceText
template: |
  {{#previousSourceText}}[Previous Paragraph]
  {{previousSourceText}}

  {{/previousSourceText}}Translate the following text into {{targetLanguageEnglishName}}{{#previousSourceText}}, using the previous paragraph only as context. Do not translate the previous paragraph{{/previousSourceText}}. Note that you should only output the translated result without any additional explanation:

  [Source Text]
  {{sourceText}}
```

`[Previous Paragraph]` is preferred over `[Background Information]` because it
describes Mercury's actual data more precisely. The previous text is not an
external glossary, user preference, document summary, or arbitrary background
note; it is the immediately preceding article segment. The label also helps make
the "do not translate the previous paragraph" instruction unambiguous.

`[Previous Text]` would be slightly more technically exact because Mercury
segments include `p`, `ul`, and `ol`, but `[Previous Paragraph]` is clearer for a
translation model and matches the dominant reader-content case.

## Language Name Tradeoff

Use a new `targetLanguageEnglishName` render parameter for the Hy-MT2 template.
This should be sourced from `AgentLanguageOption.englishName`.

Do not continue using `targetLanguageDisplayName` for the HY-MT English prompt.
That placeholder is intended for UI-style display and standard prompts. It is
generated from `Locale.current.localizedString(forIdentifier:)` and appends the
language code, so it can produce values such as:

- `Chinese (Simplified) (zh-Hans)` on an English system.
- `简体中文 (zh-Hans)` on a Chinese system.

Those values are understandable, but they do not strictly match Hy-MT2's
official guidance that English prompts should use English language names. They
also make prompt behavior depend on the user's macOS locale.

`AgentLanguageOption.englishName` already contains stable English names such as
`English`, `Chinese (Simplified)`, `Chinese (Traditional)`, `Japanese`, and
`Portuguese (Brazil)`. Reusing that existing field avoids maintaining any new
language-name table.

Do not add or maintain a Chinese language-name table for the Hy-MT2 path unless
we intentionally return to a Chinese HY-MT template after empirical testing.

## Structured Data Examples

`Structured Data 1` is not directly needed for current Reader translation.
Mercury translates extracted text segments, while HTML/list composition is
preserved by the translation composer outside the model response.

However, the example is useful future guidance for cases where Mercury might ask
the model to translate structured content directly, such as Markdown tables,
template fragments, JSON-like metadata, or placeholder-heavy text. In those
cases a separate specialized template should preserve structure, keys, and
placeholders. These rules should not be added to the normal paragraph prompt
because they would add noise and may make ordinary text translation too
conservative.

## README Update

Update the README recommendation from HY-MT1.5 to Hy-MT2:

- English section: replace `MT-1.5 1.8B` and the old
  `https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF` link with
  `Hy-MT2 1.8B` and
  `https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF`.
- Chinese section: make the same replacement in the Chinese recommendation.
- Keep the instruction that users should select `HY-MT Optimized` as the
  Translation prompt strategy when using this model family.

The README does not need to explain the prompt internals.

## Implementation Scope

For the next implementation pass:

- Add `targetLanguageEnglishName` to Translation prompt render parameters,
  sourced from `AgentLanguageOption.option(for: targetLanguage).englishName`.
- Update `translation.hy-mt.yaml` to use `targetLanguageEnglishName`.
- Update prompt tests that assert the HY-MT wording and template version.
- Update README model references.
- Do not introduce Chinese language-name plumbing or separate Chinese/English
  HY-MT templates.
