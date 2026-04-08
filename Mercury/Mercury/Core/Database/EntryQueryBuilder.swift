import Foundation
import GRDB

nonisolated struct EntryQuerySpec: Equatable, Sendable {
    var feedId: Int64?
    var unreadOnly: Bool
    var starredOnly: Bool
    var searchText: String?
    var tagIds: Set<Int64>? = nil
    var tagMatchMode: EntryStore.TagMatchMode = .any

    init(
        feedId: Int64? = nil,
        unreadOnly: Bool = false,
        starredOnly: Bool = false,
        searchText: String? = nil,
        tagIds: Set<Int64>? = nil,
        tagMatchMode: EntryStore.TagMatchMode = .any
    ) {
        self.feedId = feedId
        self.unreadOnly = unreadOnly
        self.starredOnly = starredOnly
        self.searchText = searchText
        self.tagIds = tagIds
        self.tagMatchMode = tagMatchMode
    }
}

nonisolated enum EntryQueryBuilder {
    static func buildVisibleEntries(
        spec: EntryQuerySpec = EntryQuerySpec()
    ) -> QueryInterfaceRequest<Entry> {
        var request = Entry.all()
            .filter(Column("isDeleted") == false)

        if let feedId = spec.feedId {
            request = request.filter(Column("feedId") == feedId)
        }
        if spec.unreadOnly {
            request = request.filter(Column("isRead") == false)
        }
        if spec.starredOnly {
            request = request.filter(Column("isStarred") == true)
        }

        let queryTagIDs = spec.tagIds?.sorted() ?? []
        if queryTagIDs.isEmpty == false {
            switch spec.tagMatchMode {
            case .any:
                let anyTagSubquery = EntryTag
                    .select(Column("entryId"))
                    .filter(queryTagIDs.contains(Column("tagId")))
                    .distinct()
                request = request.filter(anyTagSubquery.contains(Column("id")))
            case .all:
                for tagId in queryTagIDs {
                    let allTagSubquery = EntryTag
                        .select(Column("entryId"))
                        .filter(Column("tagId") == tagId)
                    request = request.filter(allTagSubquery.contains(Column("id")))
                }
            }
        }

        if let searchPattern = normalizedSearchPattern(from: spec.searchText) {
            let titleMatch = Column("title").collating(.nocase).like(searchPattern)
            let summaryMatch = Column("summary").collating(.nocase).like(searchPattern)
            request = request.filter(titleMatch || summaryMatch)
        }

        return request
    }

    static func buildVisibleEntry(id: Int64) -> QueryInterfaceRequest<Entry> {
        buildVisibleEntries()
            .filter(Column("id") == id)
            .limit(1)
    }

    static func buildVisibleEntries(ids: [Int64]) -> QueryInterfaceRequest<Entry> {
        buildVisibleEntries()
            .filter(ids.contains(Column("id")))
    }

    static func buildVisibleEntryIDs(
        spec: EntryQuerySpec = EntryQuerySpec()
    ) -> QueryInterfaceRequest<Entry> {
        buildVisibleEntries(spec: spec)
            .select(Column("id"))
    }

    /// Escape hatch for exceptional raw-SQL paths only.
    ///
    /// Normal app-facing entry selection should go through `buildVisibleEntries(...)` and related
    /// helpers so global visibility rules stay centralized in one query layer. This helper exists
    /// only for special cases whose query shape does not fit the shared builder cleanly today,
    /// such as the temporary related-entry recommendation query.
    static func visibleSQLPredicate(tableAlias: String? = nil) -> String {
        let qualifier = tableAlias.map { "\($0)." } ?? ""
        return "\(qualifier)isDeleted = 0"
    }

    static func applyListCursor(
        _ cursor: EntryStore.EntryListCursor,
        to request: QueryInterfaceRequest<Entry>
    ) -> QueryInterfaceRequest<Entry> {
        let publishedAt = Column("publishedAt")
        let createdAt = Column("createdAt")
        let id = Column("id")

        if let cursorPublishedAt = cursor.publishedAt {
            return request.filter(
                publishedAt < cursorPublishedAt
                    || (
                        publishedAt == cursorPublishedAt
                            && (
                                createdAt < cursor.createdAt
                                    || (createdAt == cursor.createdAt && id < cursor.id)
                            )
                    )
                    || publishedAt == nil
            )
        } else {
            return request.filter(
                publishedAt == nil
                    && (
                        createdAt < cursor.createdAt
                            || (createdAt == cursor.createdAt && id < cursor.id)
                    )
            )
        }
    }

    static func normalizedSearchText(from rawSearchText: String?) -> String? {
        let trimmedSearchText = rawSearchText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmedSearchText?.isEmpty == false) ? trimmedSearchText : nil
    }

    static func normalizedSearchPattern(from rawSearchText: String?) -> String? {
        normalizedSearchText(from: rawSearchText).map { "%\($0)%" }
    }

    static func fetchCount(
        db: Database,
        spec: EntryQuerySpec = EntryQuerySpec()
    ) throws -> Int {
        try buildVisibleEntries(spec: spec).fetchCount(db)
    }

    static func fetchUnreadCountsByFeed(_ db: Database) throws -> [Int64: Int] {
        let request = buildVisibleEntries(
            spec: EntryQuerySpec(unreadOnly: true)
        )
        let rows = try Row.fetchAll(
            db,
            request
                .select(sql: "feedId, COUNT(*) AS unreadCount")
                .group(Column("feedId"))
        )

        var result: [Int64: Int] = [:]
        for row in rows {
            guard let feedId: Int64 = row["feedId"] else { continue }
            result[feedId] = row["unreadCount"] ?? 0
        }
        return result
    }

    static func fetchUnreadCountsByTagIDs(
        _ tagIDs: [Int64],
        db: Database
    ) throws -> [Int64: Int] {
        let uniqueTagIDs = Array(Set(tagIDs)).sorted()
        guard uniqueTagIDs.isEmpty == false else { return [:] }

        let unreadVisibleEntries = buildVisibleEntries(
            spec: EntryQuerySpec(unreadOnly: true)
        ).select(Column("id"))

        let rows = try Row.fetchAll(
            db,
            EntryTag
                .filter(uniqueTagIDs.contains(Column("tagId")))
                .filter(unreadVisibleEntries.contains(Column("entryId")))
                .select(sql: "tagId, COUNT(*) AS unreadCount")
                .group(Column("tagId"))
        )

        var result: [Int64: Int] = [:]
        for row in rows {
            guard let tagId: Int64 = row["tagId"] else { continue }
            result[tagId] = row["unreadCount"] ?? 0
        }
        return result
    }
}
