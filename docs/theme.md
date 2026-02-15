# Reader Theme System — Step 0 Memo

> Date: 2026-02-15
> Last updated: 2026-02-15
> Scope: Pre-S3 reader theme system design baseline and Step 0 decisions

This memo captures the finalized design direction for the reader theme system and the concrete Step 0 outputs that must be completed before building full settings UI.

## 1. Final Decisions (Confirmed)

## 1.1 Theme strategy
Use a single `Theme` with dual variants:
- `normal` variant
- `dark` variant

The app selects variant automatically when `ThemeMode = auto`.

No separate `Theme` and `Dark Theme` user selection is introduced.

## 1.2 Built-in presets for this stage
Only two built-in presets are included:
- `classic`
- `paper`

Each preset contains both `normal` and `dark` variants.

## 1.3 Settings information architecture
The app settings UI will be organized into three sections:
- `General`
- `Reader`
- `AI Assistant`

## 1.4 Execution priority
Preview-first implementation is required:
- users should be able to preview preset themes early
- users should be able to verify token-driven changes early
- this preview milestone must be delivered before full settings UI implementation

---

## 2. Reader Theme Behavior Model

## 2.1 Core concepts
- `ThemePresetID`: `classic` | `paper`
- `ThemeMode`: `auto` | `forceLight` | `forceDark`
- `ThemeVariant`: `normal` | `dark`
- `ThemeOverride`: optional user overrides for selected tokens
- `EffectiveTheme`: merged output used by renderer

## 2.2 Variant resolution rules
1. If `ThemeMode = forceLight`, always use `normal` variant.
2. If `ThemeMode = forceDark`, always use `dark` variant.
3. If `ThemeMode = auto`, follow system appearance:
   - light appearance -> `normal`
   - dark appearance -> `dark`

## 2.3 Merge rules
`EffectiveTheme` is computed as:
1. load preset tokens by (`ThemePresetID`, `ThemeVariant`)
2. apply optional `ThemeOverride` fields
3. produce normalized token set for CSS mapping

---

## 3. Token Schema (Simple but Sufficient)

This stage uses a constrained token set to keep UX simple and implementation stable.

## 3.1 Typography tokens
- `fontFamilyBody`
- `fontSizeBody`
- `lineHeightBody`
- `contentMaxWidth`

## 3.2 Color tokens
- `colorBackground`
- `colorTextPrimary`
- `colorTextSecondary`
- `colorLink`
- `colorBlockquoteBorder`
- `colorCodeBackground`

## 3.3 Spacing and element tokens
- `paragraphSpacing`
- `headingScale`
- `codeBlockRadius`

## 3.4 Non-goals for this phase
- no free-form CSS editor
- no arbitrary selector-level style editing
- no theme import/export

---

## 4. Step 0 Deliverables (Start Now)

## 4.1 Deliverable A — Preset token definitions
Create canonical token definitions for:
- `classic.normal`
- `classic.dark`
- `paper.normal`
- `paper.dark`

Requirements:
- values must be visually coherent and readable
- `paper.dark` should preserve paper identity while meeting dark-mode contrast expectations
- preset token packs should be representable as a complete keyed set (`preset`, `variant`) and support completeness checks

## 4.2 Deliverable B — Effective theme contract
Define a stable internal contract for:
- variant resolution
- token merge behavior
- fallback defaults for missing override fields

This contract must be implementation-agnostic and testable.

## 4.3 Deliverable C — Renderer mapping contract
Define token-to-CSS mapping boundaries:
- all generated CSS must come from structured tokens
- renderer should not depend on ad-hoc style string assembly outside the mapping layer

## 4.4 Deliverable D — Cache identity strategy
Define effective cache identity for reader HTML:
- include `entryId`
- include `themePresetId`
- include resolved `variant`
- include `overrideHash`

This avoids stale cache when theme or overrides change.

## 4.5 Deliverable E — Preview-first milestone
Deliver a minimal preview path before settings UI completion:
- quickly switch between `classic` and `paper`
- quickly switch between light/dark variants
- apply one or two token overrides (for example `fontSizeBody`, `colorBackground`) and observe result immediately

This milestone is used to validate structure and reveal design issues early.

---

## 5. Proposed Implementation Sequence

## Phase P0.1 — Theme core types
- Introduce theme core types and enums (`ThemePresetID`, `ThemeMode`, `ThemeVariant`, `ThemeOverride`, `EffectiveTheme`).
- Add variant resolution utility and merge utility.

## Phase P0.2 — Preset token packs
- Add token packs for `classic` and `paper`, both with dual variants.
- Add baseline validation for token completeness.

## Phase P0.3 — Renderer integration
- Refactor renderer input to consume `EffectiveTheme`.
- Keep CSS generation centralized in one mapping layer.

## Phase P0.4 — Preview harness (before Settings)
- Add a temporary internal preview entry point for development verification.
- Validate preset switching and selected token override behavior.

## Phase P0.5 — Cache update
- Update reader cache key strategy with effective theme identity.
- Verify cache invalidation behavior after theme changes.

---

## 6. Settings UI Plan (After Preview Milestone)

## 6.1 Reader settings page
Planned controls:
- `Theme preset` selector (`classic`, `paper`)
- `Theme mode` selector (`auto`, `forceLight`, `forceDark`)
- compact token controls for typography and key colors
- reset actions (`Reset Current Theme`, `Reset Reader Settings`)

## 6.2 Preview design in settings
- include an embedded preview pane with fixed sample content
- apply changes immediately and persist automatically
- avoid modal "Apply" complexity unless performance requires delayed apply

## 6.3 Main app update behavior
- settings changes should trigger immediate reader update
- updates should propagate through a single settings store path
- no duplicate state sources for theme values

---

## 7. Risks and Mitigations

- Risk: token set grows too quickly and becomes hard to maintain.
  - Mitigation: keep strict token budget in this phase and defer advanced controls.

- Risk: paper theme in dark mode loses visual identity.
  - Mitigation: define contrast and identity checks when preparing `paper.dark`.

- Risk: preview and final renderer diverge.
  - Mitigation: use the same `EffectiveTheme` and CSS mapping path for both.

---

## 8. Step 0 Completion Checklist

- [x] `classic` and `paper` dual-variant token definitions are finalized.
- [x] variant resolution rules are documented and implemented.
- [x] token merge contract is documented and implemented.
- [x] preset token packs are keyed and completeness-checkable.
- [x] renderer consumes structured `EffectiveTheme`.
- [ ] preview-first milestone is available before full settings UI.
- [x] cache identity includes effective theme fields.
