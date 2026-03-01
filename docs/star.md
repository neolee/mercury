# Starred Entries Feature Design

## Overview

Starred entries (bookmarks/favorites) allow users to explicitly save articles for later review. The feature introduces a persistent `isStarred` flag on each entry and a dedicated **Starred** virtual feed in the sidebar.

---

## UI Design

### Sidebar: Starred Virtual Feed

A new smart feed row is added below "All Feeds" and above individual subscriptions:

```
[tray.full]  All Feeds              42
[star.fill]  Starred                 7
─────────────────────────────────────
  [feed list]
```

- Icon: `star.fill`, color `.yellow`
- Badge: total starred count (follows the same capsule style as unread count badges)
- Tag: `FeedSelection.starred`
- Selecting it loads all starred entries across all feeds, sorted by `publishedAt DESC` (same default sort as other views)
- The `unreadOnly` toggle remains functional when Starred is selected, enabling "unread starred entries" as a compound filter

### Entry List Row: Star Button

Each entry row gains a star icon on the right side:

```
●  Title text here...                   ★
   Feed Source · date
```

- **Unstarred**: `star` (outline), color `.secondary`, visible only on hover or when the row is selected — reduces visual noise
- **Starred**: `star.fill`, color `.yellow`, always visible regardless of hover state
- Icon size: ~12pt, vertically centered, right-aligned
- Clicking the icon toggles the starred state immediately (optimistic update); it does not change the selected entry

### Entry List Header

When `FeedSelection.starred` is active, the header label changes from "Entries" to "Starred" to reinforce context. The `unreadOnly` toggle and the batch-action menu remain available.

---

## Why Sidebar Virtual Feed, Not an In-List Filter Toggle

Three options were considered:

1. **Sidebar virtual feed** (like All Feeds)
2. **In-list filter toggle** (like the Unread toggle)
3. **Both**

**Option 1 is the right choice.** Starred is fundamentally a *global content collection*, not a *per-feed filter dimension*. When a user stars an article they mean "save this for later" — the result is a personal reading list that spans all subscriptions. This is categorically different from the Unread toggle, which filters within the current feed scope:

| | Unread filter | Starred view |
|---|---|---|
| Scope | Current feed | All feeds |
| Semantics | "show only unread" | "my saved articles" |
| User intent | Focus on current subscription | Cross-source retrieval / review |

Option 2 would force users to navigate to "All Feeds" first to see their complete starred collection — a two-step flow that contradicts the feature's purpose. It would also cause confusion because the starred list would appear different depending on which feed is selected.

Option 3 introduces two parallel entry points for the same concept, diluting its meaning without practical benefit. The "starred entries within a specific feed" use case is rare enough to be handled naturally by the existing `unreadOnly` compound filter.

This is also the established UX convention in comparable apps: Reeder, NetNewsWire, and ReadKit all implement starred as a sidebar virtual feed.

---

## Core Logic

### Database Migration

New migration `addEntryIsStarred`:

```sql
ALTER TABLE entry ADD COLUMN isStarred BOOLEAN NOT NULL DEFAULT 0
```

New index to support efficient starred-only paginated queries:

```sql
CREATE INDEX idx_entry_isStarred_published_created
  ON entry (isStarred, publishedAt DESC, createdAt DESC)
```

### Model Changes

**`Entry`** (add field):
```swift
var isStarred: Bool
```

**`EntryListItem`** (add field):
```swift
var isStarred: Bool
```

**`EntryListQuery`** (add field):
```swift
var starredOnly: Bool  // default false
```

**`FeedSelection`** (add case):
```swift
case starred
```

`starred` is a virtual feed (not a persisted subscription), but in current UI behavior it should follow the same interaction expectations as a normal feed selection (for example, header/toggle/search-scope behavior), not the `.all` special-case behavior.

If `feedId` for `.starred` remains `nil`, do **not** use `selectedFeedId == nil` as a proxy for `.all`; use explicit selection checks (for example, `selectedFeedSelection == .all`) so `.all` is the only special global-selection case.

### EntryStore Operations

New method, mirroring the existing `markRead` pattern:

```swift
func markStarred(entryId: Int64, isStarred: Bool) async throws
```

Implementation steps:

1. **DB write**: `Entry.filter(id == entryId).updateAll(db, Column("isStarred").set(to: isStarred))`
2. **In-memory write**: update the corresponding item in `entries`
3. **Eviction**: if the current query has `starredOnly = true` and `isStarred` is being set to `false`, remove the entry from `entries` immediately (symmetric with `unreadOnly` eviction on `markRead`)

4. **Selection handoff in starred-only list**: when the currently selected row is unstarred in a `starredOnly` view, remove it immediately and then:
  - auto-select the next row;
  - if no next row exists, select the previous row;
  - if the list becomes empty, clear selection and clear detail pane.

This auto-selection must be treated as a system-driven selection so it does not trigger auto mark-read behavior for the newly selected row.

### Query Extension

Add `isStarred` to the SELECT clause and map it to `EntryListItem`. Add the condition in the WHERE builder:

```swift
if query.starredOnly {
    conditions.append("entry.isStarred = 1")
}
```

`keepEntryId` injection remains an `unreadOnly`-specific behavior. `starredOnly` should not introduce additional keep-injection logic.

### Navigation Binding

In `ContentView+EntryLoading`, when `selectedFeed == .starred`, construct:

```swift
EntryListQuery(feedId: nil, unreadOnly: unreadOnly, starredOnly: true, ...)
```

When branching UI behavior, route by `FeedSelection` case rather than only by `feedId` optionality. `.all` is the only selection that should retain all-feeds special handling.

### Starred Count (Sidebar Badge)

Maintain `@Published var totalStarredCount: Int` in `AppModel` (or a dedicated store), driven by a GRDB `ValueObservation` on `SELECT COUNT(*) FROM entry WHERE isStarred = 1`. This is symmetric with how `totalUnreadCount` is tracked.

---

## Implementation Notes

### Star Button in macOS List

The most significant UI technical risk is preventing the star button click from triggering row selection. In a SwiftUI `List`, wrapping the icon in a `Button` with a `.plain` button style should correctly absorb the tap gesture without propagating to the row selection mechanism. This must be verified empirically.

### Hover Visibility

Use `.onHover { isHovering in ... }` on each row to drive a local `@State var isHovering: Bool`. Render the star icon only when `isHovering || entry.isStarred`, so that empty rows carry no extra visual weight.

### Optimistic Updates and Error Handling

Follow existing write-path consistency: **DB write first, then in-memory projection update**. If the DB write fails, keep in-memory state unchanged and record a debug issue. Do not surface a modal alert or status bar error (consistent with existing error surface rules).

### Index Characteristics

`isStarred` defaults to `0`, so starred rows are sparse in practice. Prefer a partial index to reduce index size while keeping starred pagination fast:

```sql
CREATE INDEX idx_entry_starred_published_created
  ON entry (publishedAt DESC, createdAt DESC)
  WHERE isStarred = 1
```

If partial indexing is not used for compatibility reasons, the composite `(isStarred, publishedAt DESC, createdAt DESC)` index remains acceptable. No per-feed starred index is needed given expected cardinality.

### Sync/Data Integrity Invariant

Star state is user-owned local state. Feed sync and entry upsert flows must not overwrite an existing row’s `isStarred` value.

---

## Localization Keys Required

| Key | Default (English) |
|---|---|
| `Starred` | `Starred` |
| (header label when starred feed is selected) | `Starred` |

If header/search-scope labels branch on selection type, include any additional static localization keys needed for starred-selection context. Avoid runtime-computed localization keys.

All display strings must resolve through `LanguageManager.shared.bundle` following the project localization rules.
