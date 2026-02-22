# Mercury 1.0 Release Plan

## Pre-1.0 — Execution Order

| # | Task | Rationale |
|---|---|---|
| 1 | ~~**Agent Availability + Onboarding UX**~~ ✅ | Product freeze first — determines what the 1.0 experience actually is |
| 2 | **Release Blocker Audit** | Freeze product state; confirm everything is clean before investing in CI |
| 3 | **Sparkle Integration** | Code-side wiring; no external dependencies on developer accounts |
| 4 | **GitHub Actions Pipeline** | Requires manual account steps (certificate export, secrets, keychain) — async with user |
| 5 | **README Rewrite** | Last; requires final screenshots of the release-ready app |

---

### Task 1 — Agent Availability Framework + Onboarding UX

#### 1.1 Availability definition

An agent is **available** if all of the following are true:

1. A `AgentTaskRouting` record exists for that task kind (summary / translation).
2. The routing's `preferredModelProfileId` references an existing model profile.
3. That model profile's provider exists and has `isEnabled == true`.

The "tested" state is deliberately **not** required for availability. Requiring a successful live test adds brittleness (test may pass and then provider goes down) and creates friction (user must manually test before features work). Instead:

- Persist `lastTestedAt: Date?` as a new optional column on `AgentModelProfile` (new DB migration).
- Update it when a test succeeds in settings.
- Display it informatively in the model settings form (e.g., "Last tested: 2 hours ago" / green dot), but do not gate availability on it.
- If the model is structurally configured but the endpoint is unreachable at runtime, the existing failure UX (error banner, `Debug Issues`) will surface it — no separate availability gate needed.

#### 1.2 Implementation: `AppModel+AgentAvailability`

New extension with two `@Published` properties and a private check method:

```swift
@Published private(set) var isSummaryAgentAvailable: Bool = false
@Published private(set) var isTranslationAgentAvailable: Bool = false

func refreshAgentAvailability() async { … }
```

`refreshAgentAvailability` is a fast DB-only read: for each task kind, walk `AgentTaskRouting → AgentModelProfile → AgentProviderProfile`; if the chain resolves and `providerProfile.isEnabled == true`, mark as available.

**When to call:**

- `AppModel.init` / app startup — call once after DB is ready
- After any provider profile save, delete, or enable toggle
- After any model profile save or delete
- On receipt of `summaryAgentDefaultsDidChange` / `translationAgentDefaultsDidChange`
- **Not** on every entry switch — availability is a function of settings, not entry state

Views observe the two `@Published` properties directly; no view-local polling needed.

**Not required for availability:** a successful test run. `lastTestedAt` (see §1.5) is decorative only.

#### 1.3 Banner upgrade: `ReaderBannerMessage`

The existing `topErrorBannerText: String?` binding (owned by `ReaderDetailView`, passed to `ReaderSummaryView` and `ReaderTranslationView`) is upgraded to `topBannerMessage: ReaderBannerMessage?`.

```swift
struct ReaderBannerMessage {
    let text: String
    let action: BannerAction?          // primary CTA (e.g. "Open Settings")
    let secondaryAction: BannerAction? // secondary CTA (e.g. "Details" → Debug Issues)

    struct BannerAction {
        let label: String
        let handler: () -> Void
    }
}
```

`ReaderDetailView.topErrorBanner(_:)` renders:
- Banner icon + selectable text (`.textSelection(.enabled)`) + spacer
- `secondaryAction` button in `.foregroundStyle(.secondary)` (if present)
- `action` primary button in `.buttonStyle(.link)` (if present)
- Dismiss (`×`) button

`BannerAction.openDebugIssues` is a static helper that returns a "Details" action in `#if DEBUG` builds and `nil` in release builds — the button is conditionally absent without any call-site `#if` guards.

All existing call sites that set `topErrorBannerText = "…"` are migrated to `topBannerMessage = ReaderBannerMessage(text: "…")` with no action — behavior is identical.

The banner is the single surface for all in-reader notifications. Future cases that need an actionable link (e.g. "Fetch failed — retry", deep links to other settings) follow the same pattern.

#### 1.4 Summary pane: agent not available

Availability banner triggers for Summary:

1. **Entry load** (`task(id: displayedEntryId)`): if `summaryText.isEmpty && !isSummaryAgentAvailable`, show the banner.
2. **Manual run button**: if `!isSummaryAgentAvailable`, set the banner and return early — do not submit to the runtime engine.

Do **not** trigger the banner from `onChange(of: isSummaryAgentAvailable)`. Reactive injection while the user is reading existing content is disruptive without benefit.

**Suppression**: the availability banner is shown at most once per unavailability period. A `summaryAvailabilityBannerSuppressed: Bool` state flag is set to `true` after the banner is first shown; it is reset to `false` via `onChange(of: isSummaryAgentAvailable)` when availability is restored. This prevents the banner from reappearing on every entry switch.

**Combined message**: when both agents are unavailable, the text reads "Agents are not configured. Add a provider and model in Settings." to avoid confusing the user with a summary-specific message when the summary pane may not even be open. When only one agent is unavailable, the message names that agent specifically.

The banner is dismissed by the user (dismiss button) or cleared when the entry changes. The existing `summaryPlaceholderText` path handles all runtime and content states; the banner handles configuration state only.

#### 1.5 Translation: agent not available

When the user clicks the translate button and `!appModel.isTranslationAgentAvailable`, `toggleTranslationMode()` returns early with an appropriate banner. The same combined-message logic as §1.4 applies: if both agents are unavailable, the text reads "Agents are not configured…"; otherwise it names the translation agent specifically.

The translate button remains visible. No `onChange` observer needed on the translation side.

#### 1.6 Error surface rules for agent failures

All agent run failures must surface **exclusively** through the Reader banner. No modal alerts, no status bar writes.

- `FailurePolicy.shouldSurfaceFailureToUser(kind:)` returns `false` for `.summary` and `.translation`.
- `AppModel+SummaryExecution` and `AppModel+TranslationExecution` skip `reportDebugIssue` when `failureReason == .noModelRoute` or `failureReason == .invalidConfiguration` — these are user-configurable states, not diagnostic anomalies.
- All other failure reasons (`.network`, `.parser`, `.storage`, `.unknown`) still write to `Debug Issues` for developer diagnostics, but do not produce modal alerts or status bar errors.
- Runtime failure banners carry a `secondaryAction` of `BannerAction.openDebugIssues`, which renders a "Details" button (debug builds only) that opens the Debug Issues panel directly from the banner.

#### 1.7 `AgentSettingsView` — `lastTestedAt` decoration

New optional column `lastTestedAt: Date?` on `AgentModelProfile` (one DB migration). After a successful test, persist `lastTestedAt = Date()`. In the model profile form, show a subtle inline label: *"Tested just now"* / *"Tested 3 h ago"* / nothing if never tested.

`lastTestedAt` is purely decorative — it does not affect availability, does not gate any feature, and is not required before agent features can be used.

#### 1.8 UI strings and l10n

All new strings in this task (and the rest of 1.0) are written as plain English string literals. L10n is deferred to a dedicated post-1.0 sprint.

To make future extraction low-cost:
- Keep all agent-status strings in `AgentRuntimeProjection` (already the pattern).
- Keep all new "not configured" / guidance strings in the same place, not inlined in view files.
- Do not use `NSLocalizedString` or `String(localized:)` yet — a global pass to adopt `String(localized:)` will be done in the l10n sprint.

---

### Task 2 — Release Blocker Audit

Before tagging `v1.0.0`, do a focused review pass:

- [ ] All known crashes and data-loss bugs are fixed
- [ ] No compiler warnings in a clean Release build (`./build`)
- [ ] All hardcoded test/debug values removed (local provider URLs, `local` API keys, debug flags)
- [ ] `CFBundleShortVersionString` and `CFBundleVersion` set to `1.0` / `1`
- [ ] App icon complete and correct at all required sizes
- [ ] Privacy manifest (`PrivacyInfo.xcprivacy`) reviewed — confirm no required-reason APIs are undeclared
- [ ] `exportOptions.plist` tested in a local archive/export dry run before first CI push

---

### Task 3 — Sparkle Auto-Update Integration

The SPM dependency (Sparkle ≥ 2.8.1) is already linked in the Xcode project. What remains:

#### 3.1 Key generation (one-time, local)

- Run `./sparkle_tools/bin/generate_keys` to produce an ed25519 key pair.
- Store the private key as the GitHub secret `SPARKLE_PRIVATE_KEY`.
- Copy the public key string into `Info.plist` as `SUPublicEDKey`.

#### 3.2 `Info.plist` additions

```xml
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/neolee/mercury/main/appcast.xml</string>
<key>SUPublicEDKey</key>
<string><!-- base64 ed25519 public key from generate_keys --></string>
```

#### 3.3 App integration (`MercuryApp.swift`)

- Instantiate `SPUStandardUpdaterController` as a stored property on `MercuryApp`.
- Start the controller with `startingUpdater: true` so Sparkle checks on launch.

#### 3.4 "Check for Updates" and Help menu items

Both go in `ContentView+Commands.swift`:

```swift
// Check for Updates — wired to Sparkle updater
CommandGroup(after: .appInfo) {
    Button("Check for Updates…") {
        updaterController.updater.checkForUpdates()
    }
}

// Help — points to online README
CommandGroup(replacing: .help) {
    Button("Mercury Help") {
        NSWorkspace.shared.open(URL(string: "https://github.com/neolee/mercury#readme")!)
    }
}
```

The Help item serves double duty: satisfies the macOS Help menu convention and provides a direct path to the bilingual README guide from within the app — a lightweight complement to any in-app guidance text.

#### 3.5 Seed `appcast.xml` in the repository

Create a minimal placeholder `appcast.xml` at the repo root so Sparkle finds a valid feed on first CI build (`generate_appcast` will overwrite it on release).

---

### Task 4 — GitHub Actions Release Pipeline

Triggered on `push` to tags matching `v*`. Adapts the reference workflow for Mercury (no Rust core; Developer ID direct distribution).

This task involves manual steps that must be done by the developer before the workflow can run: exporting the Developer ID certificate, generating an App-Specific Password, and configuring repository secrets. These are listed in 4.3.

#### 4.1 `exportOptions.plist` (commit to repo root)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
```

#### 4.2 Workflow steps (`release.yml`)

1. **Checkout** (`fetch-depth: 0` — required for `generate_appcast` to walk tags)
2. **Check environment versions** (macOS, Xcode, SDK — diagnostic only)
3. **Install Apple certificate** into a temporary ephemeral keychain
4. **Build and archive** — `xcodebuild archive`, project `Mercury/Mercury.xcodeproj`, scheme `Mercury`, `Developer ID Application`, `--timestamp`
5. **Export app** — `xcodebuild -exportArchive` with `exportOptions.plist`
6. **Notarize** — `xcrun notarytool submit … --wait`; fail the job if status ≠ Accepted
7. **Staple** — `xcrun stapler staple`
8. **Create DMG** — `create-dmg` with Mercury branding (volname, icon layout)
9. **Cache Sparkle tools** — cache `sparkle_tools/bin/generate_appcast` keyed by Sparkle version
10. **Generate Sparkle metadata** — `generate_appcast --ed-key-file - --link … --download-url-prefix …`
11. **Commit and push `appcast.xml`** — back to `main` with `[skip ci]`
12. **Create GitHub Release** — attach `Mercury.dmg`

#### 4.3 Required GitHub secrets (manual setup checklist)

- [ ] Export Developer ID Application certificate from Keychain → `.p12`, base64-encode → `CERTIFICATE_P12`
- [ ] Record the `.p12` export password → `CERTIFICATE_PASSWORD`
- [ ] Choose any random string for ephemeral keychain → `KEYCHAIN_PASSWORD`
- [ ] Apple ID email used for notarization → `APPLE_ID`
- [ ] Generate App-Specific Password at appleid.apple.com → `APPLE_PASSWORD`
- [ ] Apple Developer Team ID (from developer.apple.com) → `TEAM_ID`
- [ ] Sparkle ed25519 private key from `generate_keys` (base64) → `SPARKLE_PRIVATE_KEY`

---

### Task 5 — README Rewrite

Full replacement of the current placeholder README. Structure:

1. **Header** — name, one-line description, badge (latest release)
2. **Screenshots** — 2–3 images: main reading view, summary/translation panel, agent settings
3. **Features** — concise bullet list matching actual 1.0 capabilities
4. **Requirements** — macOS version minimum; no account, no subscription, no login
5. **Installation** — download DMG from GitHub Releases, drag to Applications
6. **Getting Started**
   - Adding feeds (manual URL, OPML import)
   - Agent setup: provider base URL, API key, model selection
   - Using Summary and Translation
   - Customizing prompts
7. **Privacy** — local-first, no telemetry, no login
8. **Building from Source** — `./build`, Xcode version, SPM dependencies auto-resolved
9. **License**

Bilingual: English first, Chinese follows under `---`. Same headings, translated. Single file — no separate Chinese README.

Screenshots: take after the app is in final release-ready state. Minimum:
- Main reading view with an article open
- Summary panel populated with a result
- Agent settings page

---

## Post-1.0

### Localization (zh-Hans)

A dedicated sprint, not entangled with feature work. Prerequisites: feature set is stable and the rate of new UI strings has dropped significantly.

Scope:
- Global pass to replace string literals with `String(localized:)` (or `LocalizedStringKey` in SwiftUI contexts).
- Extract to `.xcstrings` (Xcode String Catalog).
- Provide zh-Hans translations for all keys.
- Add zh-Hans entry to the README bilingual section noting the supported interface language.

The groundwork laid in 1.0 (all agent-status strings centralized in `AgentRuntimeProjection`, guidance strings not inlined in views) keeps the extraction cost low.

### Tag System

The largest post-1.0 feature. Requires a dedicated design document before implementation begins (see `docs/tag-system.md` — to be created).

High-level scope:

- **Data model**: `Tag` table, `EntryTag` join table; tags are user-defined strings; an entry may have multiple tags.
- **Tag Agent**: a new agent kind (`AgentTaskKind.tagging`) that calls the LLM to suggest tags for an entry based on its content; user can accept, edit, or ignore.
- **Batch tagging**: run Tag Agent over a set of entries (e.g., all unread, or a feed); uses `TaskQueue` bounded parallelism consistent with sync concurrency policy.
- **Tag filter UI**: sidebar section or toolbar filter control to scope the entry list to one or more selected tags.
- **Entry list integration**: `EntryListItem` shows tag chips (or a count badge for space efficiency).

Sequence dependency: Tag Agent design → data model migration → Tag Agent runtime integration → batch flow → UI.

### Multi-Entry Summary

Two distinct sub-features with different dependencies:

- **Digest of all new entries** — independent of the tag system; produces a single AI-generated briefing across N entries fetched since the last read date. Can ship as a standalone feature.
- **Digest of entries in selected tag(s)** — depends on Tag System being shipped first.

The multi-entry summary uses a different prompt strategy than single-entry summary (aggregation vs. extraction). A separate prompt template (`multi-summary.default.yaml`) and a new `AgentTaskKind` variant will be needed.

Design note: the existing `AgentRuntimeEngine` concurrency model is single-slot per kind per entry; multi-entry summary needs a different ownership model (job-level, not entry-level).

### LLM Token Usage Monitoring

Scope: track prompt and completion token counts per agent run; surface totals in a dedicated diagnostics view or a usage section in agent settings.

Data: store token counts in the existing `ai_task_run` table (add `promptTokens` and `completionTokens` integer columns; migration version bump required).

Source: read from `usage` field in the OpenAI-compatible response (available in both streaming final chunk and non-streaming response body).

UI: a simple table or chart in settings showing per-model, per-kind usage over time. No external analytics — all local.

This feature is scoped independently of Tag System and can ship in any order after 1.0.
