# Tags System v2 Technical Contracts (Blueprint)

> Date: 2026-03-01
> Status: Blueprint
> Audience: Developers, AI Coding Agents
> Scope: Hard technical constraints for implementing `tags-v2.md`

This document defines the strict, non-negotiable coding contracts to guarantee that the Tags System integrates safely into Mercury's Swift/macOS/GRDB architecture without violating existing policies.

---

## 1. Data Store Contracts (GRDB)

### 1.1 Model Naming and Conformances
All models must live in `Mercury/Core/Database/Models.swift` (or a dedicated `Models+Tags.swift` if preferred). Let's keep it simple: `Tag`, `TagAlias`, and `EntryTag`.

**Required Definitions:**
```swift
struct Tag: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "tag"
    
    var id: Int64?
    var name: String
    var normalizedName: String
    var isProvisional: Bool
    var usageCount: Int
    // ...
}

struct TagAlias: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "tag_alias"
    
    var id: Int64?
    var tagId: Int64
    var alias: String
    var normalizedAlias: String
}

struct EntryTag: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "entry_tag"
    
    var entryId: Int64
    var tagId: Int64
    var source: String // e.g. "rss", "nlp", "ai", "manual"
    var confidence: Double?
}
```

### 1.2 GRDB Associations
In `Models.swift`, establish the relationship so `Entry` can fetch `tags` cleanly:
```swift
extension Entry {
    static let entryTags = hasMany(EntryTag.self)
    static let tags = hasMany(Tag.self, through: entryTags, using: EntryTag.tag)
}

extension Tag {
    static let entryTags = hasMany(EntryTag.self)
    static let entries = hasMany(Entry.self, through: entryTags, using: EntryTag.entry)
    static let aliases = hasMany(TagAlias.self)
}

extension EntryTag {
    static let entry = belongsTo(Entry.self)
    static let tag = belongsTo(Tag.self)
}
```

### 1.3 Transaction Boundary Requirements
Tag assignment is a multi-step mutation (check for tag -> update/insert tag -> insert `entry_tag` -> calculate `isProvisional`). 
**DO NOT use multiple UI calls.** These MUST occur inside a central `db.write { db in ... }` transaction within a dedicated method `EntryStore.assignTags(to entryId: Int64, names: [String], source: String)`.

---

## 2. Navigation & UI State Boundaries

### 2.1 Navigation Root
Keep navigation changes within the existing `FeedSelection`-driven path (ContentView selection + query token flow), and add a tag selection branch there.
Do not introduce a broad global `NavigationState` refactor during this phase.

### 2.2 EntryListQuery Extension
Filtering happens directly in `EntryStore.EntryListQuery` and `makeEntryQueryToken(...)`.
Add:
```swift
public var tagIds: Set<Int64>?
public var tagMatchMode: TagMatchMode = .any
```

### 2.3 Batch Actions Consistency
Batch actions (*Mark All as Read*) currently respect `feed scope + unread filter + search filter`. 
**Requirement:** `Tag Filter` MUST be appended to `MarkReadPolicy` contexts to ensure "Mark All as Read" inside a Tag view only marks entries associated with that tag, strictly respecting the query.

---

## 3. NLP and Execution Constraints

### 3.1 NLTagger Execution thread
Apple's `NLTagger` is fully synchronous.
**Contract:** The `NaturalLanguage` execution code must be wrapped in an `async` function and executed off the `MainActor` (e.g., using a background `actor LocalTaggingService { ... }` or `Task.detached`). DO NOT invoke `NLTagger.enumerateTags(...)` inside View `.task {}` modifiers or `@MainActor` closures.

### 3.2 Parsing Timing
- `Metadata Pass (RSS <category>)`: Happens at the `FeedParser` level BEFORE database insertion.
- `Local NLP Pass (NLTagger)`: Scheduled passively or dynamically upon list viewing. (Avoid running NLP on 1000s of unread titles blockingly).

---

## 4. Agent Task Queue Integration

Tag generation via LLM will be orchestrated by `AgentRuntimeEngine` and `TaskCenter`.

### 4.1 Integration Pattern
Follow the exact pattern set by `AppModel+SummaryExecution.swift`.
- Create `AppModel+TagExecution.swift`.
- Map `AgentTaskKind.tagging`.
- Implement `executeTaggingTask(for owner: AgentRunOwner, using token: ...)`.

### 4.2 Rate Limiting and Resilience
- A "Batch Tagging" operation over older entries must respect `AgentRuntimePolicy.perTaskConcurrencyLimit[.tagging]`. Do NOT spin up boundless unstructured `TaskGroup` iterations.
- If the app is force-closed, the `AgentRuntimeStore` persists the queue. The tag agent must correctly restore/abandon states `.wait` or `.generating` on launch.

### 4.3 Routing and Timeout Transition Contract
- Early implementation may temporarily reuse current routing semantics.
- Before Phase 4 is marked complete, tagging must have explicit route/timeout behavior documented and wired consistently with telemetry and failure classification.

### 4.4 Error Handling Surface
- **STRICT PROHIBITION:** Do not throw modal `.alert` dialogs for LLM route failures, API rate limits, or parse errors during batch/lazy tagging.
- Failures (`.noModelRoute`, `.invalidConfiguration`) must degrade silently or surface only via local Reader space notifications (e.g., a small banner above the article: "Tag generation paused: API Limit Reached"). Follow `FailurePolicy.shouldSurfaceFailureToUser`.