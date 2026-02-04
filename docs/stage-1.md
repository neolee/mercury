# Stage 1 — Basic RSS Reader (Plan)

> Date: 2026-02-03

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
- Clean with Readability + SwiftSoup
- Store raw HTML + cleaned Markdown

**Verification**:
- Content saved and retrievable

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
- Run `./build` script to ensure clean build and catch any integration issues early.