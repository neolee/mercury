# Reader Custom Font Support

## Scope

Add user-selectable custom font family support to Reader mode while preserving the existing reader theme architecture, cache behavior, and `UserDefaults`-backed preference flow.

This document captures the final design decisions before implementation.

## Goals

- Keep the current theme token pipeline intact.
- Preserve the existing built-in font options.
- Add one custom font option that lets the user choose any installed font family.
- Ensure custom font changes participate in reader cache identity automatically.
- Reuse one shared font-family chooser UI from both Settings and the Reader theme panel.

## Non-Goals

- No database schema changes.
- No `readerRenderVersion` bump.
- No free-form CSS editing.
- No selection of font size, weight, or traits from the custom font UI.
- No import/export or sync of font settings beyond existing app preference storage.

## Core Model

Keep `ReaderThemeFontFamilyOptionID` as the authoritative selection enum and add:

- `custom`

Keep the existing built-in cases unchanged:

- `usePreset`
- `systemSans`
- `readingSerif`
- `roundedSans`
- `mono`

Add one separate persisted value for the chosen custom family name:

- `readerThemeOverrideCustomFontFamilyName`

This keeps the current enum-based theme setting intact while avoiding overloaded storage semantics.

## Persistence

Theme font settings remain app-level preferences in `UserDefaults` via `@AppStorage`.

Persisted keys:

- Existing: `readerThemeOverrideFontFamily`
  - Stores the enum raw value, now including `custom`.
- New: `readerThemeOverrideCustomFontFamilyName`
  - Stores the selected installed font family name, for example `Baskerville`.

Reset behavior:

- Resetting theme overrides must reset the enum selection to `usePreset`.
- Resetting theme overrides must clear the custom family name.

## CSS Mapping

The current theme pipeline already renders any `fontFamilyBody` string into CSS, so custom font support should be implemented by extending font-family resolution only.

Implementation shape:

- Keep built-in cases mapped to fixed CSS stacks.
- `usePreset` still returns `nil`.
- `custom` constructs a CSS `font-family` value from:
  - the selected custom family name
  - a coarse fallback stack chosen by font classification

Example outputs:

- Serif custom font:
  - `"Baskerville", "Iowan Old Style", "New York", Charter, Georgia, "Times New Roman", serif`
- Sans custom font:
  - `"PingFang SC", -apple-system, system-ui, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif`
- Monospace custom font:
  - `"SF Mono", Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace`

Classification policy:

- Classify the chosen family into one of:
  - `serif`
  - `sans`
  - `mono`
- If classification is unknown, fall back to the sans stack.

Escaping:

- The selected family name must be safely quoted/escaped before generating CSS.

## Theme Integration

No structural change is needed in the reader rendering path.

The integration point remains `ReaderThemeRules.makeOverride(...)`:

- Resolve the selected font option.
- If the option is `custom`, read `customFamilyName`.
- Construct the CSS `font-family` string.
- Assign it to `ReaderThemeOverride.fontFamilyBody`.

Because `EffectiveReaderTheme.cacheThemeID` is already derived from final theme tokens, custom font changes will automatically:

- change the effective theme fingerprint
- invalidate reader HTML cache for the changed theme identity
- force visible reader refresh through the existing theme identity flow

## Font Chooser UI

Implement one shared font-family chooser content component focused only on font family selection.

Data source:

- installed font families from the macOS font system

Chooser content:

- search field
- scrollable list of font family names
- each row rendered using its own family name when possible
- lightweight preview shown inside the chooser only
- confirm and cancel actions as appropriate for the container style

The chooser is family-only by design:

- no weight picker
- no style picker
- no size controls

## Settings UI

Settings remains the primary persistent configuration surface.

In Reader Settings:

- keep the existing `Font Family` control
- add `Custom` as a menu option
- when `Custom` is selected, show:
  - current selected family name
  - `Choose Font…` action

Presentation:

- in Settings, the chooser may be presented as a sheet

Preview:

- preview stays in the chooser and in the existing Reader live preview
- no extra large preview block is needed in the settings form row itself

## Reader Theme Panel UI

The Reader theme panel must remain compact and must not be dismissed by font selection.

Behavior:

- keep the existing `Font Family` menu
- add `Custom` as a menu option
- when `Custom` is selected, show one compact extra row:
  - the current custom family name
  - a minimal icon-only action to reopen the chooser

Layout constraints:

- do not add a separate preview text block in the theme panel
- the family name itself may render in its own font and act as a lightweight preview
- allow the panel height to grow naturally to fit the extra row

Presentation:

- in the Reader theme panel, do not present the chooser in a way that closes the theme panel
- prefer a lightweight attached presentation such as a dedicated popover-style surface
- reuse the same chooser content component used by Settings

## Behavioral Constraints

- Built-in font options must continue to behave exactly as before.
- `usePreset` must keep using the theme preset's typography tokens.
- Custom font selection must be ignored if no valid custom family name is available, falling back safely rather than producing invalid CSS.
- Reader preview and final reader rendering must continue to use the same effective theme path.

## Testing Expectations

Add tests for:

- `custom` font option generates CSS with the correct fallback stack class
- custom family changes alter `cacheThemeID`
- resetting theme overrides clears custom font state
- built-in font options remain unchanged
- invalid or empty custom family input fails safely

## Implementation Notes

Preferred implementation order:

1. Extend font-family model and storage.
2. Add custom CSS font-family construction with coarse classification.
3. Add the shared chooser content component.
4. Wire Settings presentation.
5. Wire Reader theme panel presentation without dismissing the panel.
6. Add tests and localization strings.
