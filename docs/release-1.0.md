# Mercury 1.0 Release Plan

## Pre-1.0

### 1. Sparkle Auto-Update Integration

The SPM dependency (Sparkle ≥ 2.8.1) is already linked in the Xcode project. What remains:

#### 1.1 Key generation (one-time, local)

- Run `./sparkle_tools/bin/generate_keys` to produce an ed25519 key pair.
- Store the private key as the GitHub secret `SPARKLE_PRIVATE_KEY`.
- Copy the public key string into `Info.plist` as `SUPublicEDKey`.

#### 1.2 Info.plist additions

Add to `Mercury/Mercury/Info.plist`:

```xml
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/neolee/mercury/main/appcast.xml</string>
<key>SUPublicEDKey</key>
<string><!-- base64 ed25519 public key from generate_keys --></string>
```

#### 1.3 App integration (`MercuryApp.swift`)

- Instantiate `SPUStandardUpdaterController` as a stored property on `AppDelegate` or as a `@StateObject` on `MercuryApp`.
- Start the controller with `startingUpdater: true` so Sparkle checks on launch.

#### 1.4 "Check for Updates" menu item

- Add a `Button("Check for Updates…")` to the app menu in `ContentView+Commands.swift`.
- Wire it to `updaterController.updater.checkForUpdates()`.

#### 1.5 Seed `appcast.xml` in the repository

Create a minimal placeholder `appcast.xml` at the repo root so Sparkle finds a valid feed on first build (`generate_appcast` will overwrite it on release).

---

### 2. GitHub Actions Release Pipeline

Triggered on `push` to tags matching `v*`. Adapts the reference workflow for Mercury (no Rust core; Developer ID direct distribution).

#### 2.1 `exportOptions.plist` (commit to repo root)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$(TEAM_ID)</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
```

Note: the `teamID` value is substituted at export time via the `DEVELOPMENT_TEAM` build setting; the plist just needs `method: developer-id`.

#### 2.2 Workflow steps (`release.yml`)

1. **Checkout** (`fetch-depth: 0` for `generate_appcast` to walk tags)
2. **Check environment versions** (macOS, Xcode, SDK — diagnostic)
3. **Install Apple certificate** into a temporary keychain
4. **Build and archive** — `xcodebuild archive` targeting `Mercury/Mercury.xcodeproj`, scheme `Mercury`, `Developer ID Application`, `--timestamp`
5. **Export app** — `xcodebuild -exportArchive` with `exportOptions.plist`
6. **Notarize** — `xcrun notarytool submit … --wait`; fail the job if status ≠ Accepted
7. **Staple** — `xcrun stapler staple`
8. **Create DMG** — `create-dmg` with Mercury branding (volname, icon layout)
9. **Cache Sparkle tools** — cache `sparkle_tools/bin/generate_appcast` by version key
10. **Generate Sparkle metadata** — `generate_appcast --ed-key-file - --link … --download-url-prefix …`
11. **Commit and push `appcast.xml`** — back to `main` with `[skip ci]`
12. **Create GitHub Release** — attach `Mercury.dmg`

#### 2.3 Required GitHub secrets

| Secret | Description |
|---|---|
| `CERTIFICATE_P12` | Developer ID Application certificate (base64-encoded `.p12`) |
| `CERTIFICATE_PASSWORD` | Password for the `.p12` file |
| `KEYCHAIN_PASSWORD` | Ephemeral keychain password (any random string) |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_PASSWORD` | App-specific password for that Apple ID |
| `TEAM_ID` | Apple Developer Team ID |
| `SPARKLE_PRIVATE_KEY` | ed25519 private key from `generate_keys` (base64) |

---

### 3. README Rewrite

Full replacement of the current placeholder README. Structure:

1. **Header** — name, one-line description, badge (latest release)
2. **Screenshots** — 2–3 images covering the main reading view, the summary/translation panel, and the agent settings page
3. **Features** — concise bullet list; mirror the app's actual capabilities at 1.0
4. **Requirements** — macOS version minimum, no account required, no subscription
5. **Installation** — download DMG from GitHub Releases, drag to Applications
6. **Getting Started**
   - Adding feeds (manual URL, OPML import)
   - Agent setup: provider base URL, API key, model selection
   - Using Summary and Translation
   - Customizing prompts
7. **Privacy** — local-first data, no telemetry, no login
8. **Building from Source** — `./build` prerequisite, Xcode version, SPM dependencies auto-resolved
9. **License**

Bilingual: English first, Chinese section follows under an `---` separator or as a parallel section. Use the same headings translated; do not maintain two separate files.

Screenshot placement: take screenshots after the app is in a representative release-ready state. At minimum capture:
- Main reading view with an article open
- Summary panel populated
- Agent settings page

---

### 4. First-Run Onboarding

The agent features are non-functional until the user configures a provider. New users who open the app and see "No summary" / "No translation" with no indication of why will abandon the feature.

Minimum viable approach (no separate onboarding screen required):

- **Empty state copy in agent panels**: when no provider is configured, replace the neutral placeholder with a short message and a direct link to the Agents settings tab, e.g.:  
  *"Configure an LLM provider in Settings → Agents to enable summaries."*
- **Agent settings validation banner**: show an inline warning in `AgentSettingsView` when the provider URL or API key is empty, before the user tries to run anything.

This is a UI task scoped to `ReaderDetailView`, the summary/translation empty-state views, and `AgentSettingsView`.

---

### 5. Release Blocker Audit

Before tagging `v1.0.0`, do a focused review pass:

- [ ] All known crashes and data-loss bugs are fixed
- [ ] No compiler warnings in a clean Release build (`./build`)
- [ ] All hardcoded test/debug values removed (local provider URLs, `local` API keys, debug flags)
- [ ] `CFBundleShortVersionString` and `CFBundleVersion` set to `1.0` / `1`
- [ ] App icon complete and correct at all required sizes
- [ ] Privacy manifest (`PrivacyInfo.xcprivacy`) reviewed — confirm no required reason APIs are undeclared
- [ ] `exportOptions.plist` tested in a local archive/export dry run before first CI push

---

## Post-1.0

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
