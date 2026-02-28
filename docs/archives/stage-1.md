# Stage 1 — Basic RSS Reader (Plan)

> Date: 2026-02-03
> Last updated: 2026-02-15

This document captures the unified Stage 1 plan and the step-by-step implementation breakdown. Stage 1 covers the **complete basic RSS reader** feature set (not just a single step), with implementation proceeding in ordered steps.

## Scope (Stage 1)
- Full basic RSS reader capability on macOS (SwiftUI)
- GRDB-backed local persistence
- Feed CRUD
- OPML import/export
- Entry syncing and deduplication
- HTML downloading and cleaning
- Content storage (HTML + cleaned Markdown)
- Reading mode toggle (WebView vs cleaned content)
- Unread counts and read-state handling

## Unified Architecture (one-time design)
- Data models: `Feed`, `Entry`, `Content`
- Persistence: `SQLite` via `GRDB`
- State: `AppModel` / `FeedStore` / `EntryStore` / `ContentStore`
- Networking/sync: centralized `SyncService`
- UI binding: `ObservableObject`-driven SwiftUI state

## Step-by-step Implementation Plan (Stage 1)

### Step 1 — Data Layer + State Foundation
**Goal**: Build the GRDB schema/migrations and the SwiftUI state skeleton.
- GRDB schema + migrations
- Basic CRUD for `feed`, `entry`, `content`
- `AppModel` with stores and state flow

**Verification**:
- App launches without database errors
- Can insert and query feeds/entries/content
- State updates propagate to UI

---

### Step 2 — OPML Import & Initial Sync (Top 10)
- Parse `hn-popular.opml` and import first 10 feeds
- FeedKit fetch + parse
- Deduplicate entries by `guid`/`url`

**Verification**:
- Auto-imports 10 feeds on first run
- Sync produces entries with no duplicates

---

### Step 3 — Three-pane UI + WebKit Reading
- Left: feed list + unread count
- Middle: entry list
- Right: `WKWebView` for `entry.url`

**Verification**:
- Layout stable across window sizes
- Selecting an entry loads the page in WebView

---

### Step 4 — Read/Unread State & Visuals
- Mark entry read on selection
- Update per-feed and total unread counts
- Elegant unread styling + badge

**Verification**:
- Unread counts update immediately and persist
- Visual indicators are clear and consistent

---

### Step 5 — Feed CRUD
- Add feed by URL
- Delete feed
- Edit feed (name, URL)

**Verification**:
- CRUD operations persist and update UI

---

### Step 6 — OPML Import/Export
- Import from file
- Export current subscriptions

**Verification**:
- Exported OPML can be re-imported

---

### Step 7 — HTML Download + Clean + Store
- Download HTML
- Clean with Readability (pure Swift) + SwiftSoup
- Store raw HTML + cleaned Markdown
- Render `cleanMarkdown` → `cleanHTML` using Down (cmark-gfm)
- Cache rendered HTML in a dedicated table keyed by `themeId + entryId`

**Verification**:
- Content saved and retrievable
- Cached `cleanHTML` reused for same `themeId + entryId`

---

### Step 8 — Reading Mode Toggle
- Toggle between WebView and cleaned content

**Verification**:
- Mode switching works without reload errors

---

## Initial Decisions
- OPML import: first 10 feeds
- Unread UI: numeric badge + unread highlight
- Reading: embedded WebKit only (no external browser)

## Verification
- Clarify verification criteria for each step to ensure clear success metrics and testing focus.
- Run `./scripts/build` script to ensure clean build and catch any integration issues early.

## Current Progress (2026-02-11)
- Steps 1-8 are implemented in the codebase.
- Readability parsing uses the pure Swift port (no WKWebView).

## Stage 1 Closure Status (2026-02-15)
- Stage 1 is closed as completed.
- The application satisfies Stage 1 target: a usable baseline RSS reader with feed management, sync, reading modes, OPML import/export, and unread-state handling.
- Build baseline remains healthy via `./scripts/build`.

## Deferred Items (Not Stage 1 Scope)
- AI capabilities (auto-tagging/translation/summarization) belong to later stages.
- `README.md` stays as a placeholder until pre-`1.0` release, and is not a Stage 1 completion requirement.