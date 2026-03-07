//
//  TagLibraryStore.swift
//  Mercury
//

import Foundation
import GRDB

enum TagLibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case provisional
    case unused
    case hasAliases
    case potentialDuplicates

    var id: String { rawValue }
}

struct TagLibraryListItem: Identifiable, Equatable, Sendable {
    let tagId: Int64
    let name: String
    let normalizedName: String
    let isProvisional: Bool
    let usageCount: Int
    let aliasCount: Int
    let hasPotentialDuplicates: Bool

    var id: Int64 { tagId }
}

struct TagLibraryAliasItem: Identifiable, Equatable, Sendable {
    let aliasId: Int64
    let alias: String
    let normalizedAlias: String

    var id: Int64 { aliasId }
}

struct TagDuplicateCandidate: Identifiable, Equatable, Sendable {
    enum Reason: String, Sendable {
        case pluralizationVariant
        case nearSpellingVariant
        case likelyNamingVariant
    }

    let tagId: Int64
    let name: String
    let usageCount: Int
    let reason: Reason

    var id: Int64 { tagId }
}

struct TagLibraryInspectorSnapshot: Equatable, Sendable {
    let tagId: Int64
    let name: String
    let normalizedName: String
    let isProvisional: Bool
    let usageCount: Int
    let aliases: [TagLibraryAliasItem]
    let potentialDuplicates: [TagDuplicateCandidate]
    let isMutationAllowed: Bool
}

@MainActor
final class TagLibraryStore {
    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func fetchTagLibraryItems(
        filter: TagLibraryFilter,
        searchText: String? = nil
    ) async -> [TagLibraryListItem] {
        let trimmedSearchText = searchText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSearchText = (trimmedSearchText?.isEmpty == false) ? trimmedSearchText : nil
        let searchPattern = normalizedSearchText.map { "%\($0)%" }

        do {
            let baseItems = try await db.read { db in
                let duplicateCandidatesByTagID = try Self.loadDuplicateCandidatesByTagID(db: db)
                var conditions: [String] = []
                var arguments: StatementArguments = []

                switch filter {
                case .all, .potentialDuplicates:
                    break
                case .provisional:
                    conditions.append("t.isProvisional = 1")
                case .unused:
                    conditions.append("t.usageCount = 0")
                case .hasAliases:
                    conditions.append("EXISTS (SELECT 1 FROM tag_alias a2 WHERE a2.tagId = t.id)")
                }

                if let searchPattern {
                    conditions.append(
                        """
                        (
                            t.name LIKE ? COLLATE NOCASE
                            OR t.normalizedName LIKE ? COLLATE NOCASE
                            OR EXISTS (
                                SELECT 1
                                FROM tag_alias a3
                                WHERE a3.tagId = t.id
                                  AND (a3.alias LIKE ? COLLATE NOCASE OR a3.normalizedAlias LIKE ? COLLATE NOCASE)
                            )
                        )
                        """
                    )
                    arguments += [searchPattern, searchPattern, searchPattern, searchPattern]
                }

                var sql = """
                SELECT
                    t.id AS tagId,
                    t.name AS name,
                    t.normalizedName AS normalizedName,
                    t.isProvisional AS isProvisional,
                    t.usageCount AS usageCount,
                    COUNT(a.id) AS aliasCount
                FROM tag t
                LEFT JOIN tag_alias a ON a.tagId = t.id
                """

                if conditions.isEmpty == false {
                    sql += " WHERE " + conditions.joined(separator: " AND ")
                }

                sql += """
                 GROUP BY t.id
                 ORDER BY t.usageCount DESC, t.normalizedName ASC
                """

                let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
                return rows.compactMap { row -> TagLibraryListItem? in
                    guard
                        let tagId: Int64 = row["tagId"],
                        let name: String = row["name"],
                        let normalizedName: String = row["normalizedName"]
                    else {
                        return nil
                    }

                    return TagLibraryListItem(
                        tagId: tagId,
                        name: name,
                        normalizedName: normalizedName,
                        isProvisional: row["isProvisional"] ?? false,
                        usageCount: row["usageCount"] ?? 0,
                        aliasCount: row["aliasCount"] ?? 0,
                        hasPotentialDuplicates: duplicateCandidatesByTagID[tagId]?.isEmpty == false
                    )
                }
            }

            guard filter == .potentialDuplicates else {
                return baseItems
            }
            return baseItems.filter { $0.hasPotentialDuplicates }
        } catch {
            return []
        }
    }

    func loadInspectorSnapshot(tagId: Int64) async -> TagLibraryInspectorSnapshot? {
        do {
            return try await db.read { db -> TagLibraryInspectorSnapshot? in
                guard let tag = try Tag.fetchOne(db, key: tagId) else {
                    return nil
                }
                let duplicateCandidatesByTagID = try Self.loadDuplicateCandidatesByTagID(db: db)

                let aliasRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id AS aliasId, alias, normalizedAlias
                    FROM tag_alias
                    WHERE tagId = ?
                    ORDER BY normalizedAlias ASC
                    """,
                    arguments: [tagId]
                )
                let aliases = aliasRows.compactMap { row -> TagLibraryAliasItem? in
                    guard
                        let aliasId: Int64 = row["aliasId"],
                        let alias: String = row["alias"],
                        let normalizedAlias: String = row["normalizedAlias"]
                    else {
                        return nil
                    }
                    return TagLibraryAliasItem(aliasId: aliasId, alias: alias, normalizedAlias: normalizedAlias)
                }

                let hasActiveBatchRun = try TagBatchRun
                    .filter(TagBatchRunStatus.activeLifecycleRawValues.contains(Column("status")))
                    .fetchCount(db) > 0

                return TagLibraryInspectorSnapshot(
                    tagId: tagId,
                    name: tag.name,
                    normalizedName: tag.normalizedName,
                    isProvisional: tag.isProvisional,
                    usageCount: tag.usageCount,
                    aliases: aliases,
                    potentialDuplicates: duplicateCandidatesByTagID[tagId] ?? [],
                    isMutationAllowed: !hasActiveBatchRun
                )
            }
        } catch {
            return nil
        }
    }

    func mergeTag(sourceID: Int64, targetID: Int64) async throws {
        guard sourceID != targetID else {
            throw TagMutationError.cannotMergeIntoSelf
        }

        try await db.write { db in
            try TagMutationPolicy.assertNoActiveBatchLifecycle(db)

            guard let sourceTag = try Tag.fetchOne(db, key: sourceID) else {
                throw TagMutationError.tagNotFound
            }
            guard let targetTag = try Tag.fetchOne(db, key: targetID) else {
                throw TagMutationError.tagNotFound
            }

            let sourceAliases = try TagAlias
                .filter(Column("tagId") == sourceID)
                .fetchAll(db)

            try db.execute(
                sql: """
                INSERT OR IGNORE INTO entry_tag (entryId, tagId, source, confidence)
                SELECT entryId, ?, source, confidence
                FROM entry_tag
                WHERE tagId = ?
                """,
                arguments: [targetID, sourceID]
            )
            try db.execute(sql: "DELETE FROM entry_tag WHERE tagId = ?", arguments: [sourceID])

            for sourceAlias in sourceAliases {
                guard let aliasID = sourceAlias.id else { continue }
                guard try Self.canSafelyAttachAlias(
                    normalizedAlias: sourceAlias.normalizedAlias,
                    targetTag: targetTag,
                    sourceTagID: sourceID,
                    db: db
                ) else {
                    continue
                }

                try db.execute(
                    sql: "UPDATE tag_alias SET tagId = ? WHERE id = ?",
                    arguments: [targetID, aliasID]
                )
            }

            if try Self.canSafelyAttachAlias(
                normalizedAlias: sourceTag.normalizedName,
                targetTag: targetTag,
                sourceTagID: sourceID,
                db: db
            ) {
                var alias = TagAlias(
                    id: nil,
                    tagId: targetID,
                    alias: sourceTag.name,
                    normalizedAlias: sourceTag.normalizedName
                )
                try alias.insert(db)
            }

            try TagMutationPolicy.deleteTagRows(id: sourceID, db: db)
            try Self.refreshUsageCount(for: targetID, db: db)
        }
    }

    func addAlias(tagId: Int64, alias: String) async throws {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw TagMutationError.emptyName }

        let normalizedAlias = TagNormalization.normalize(trimmed)
        guard normalizedAlias.isEmpty == false else { throw TagMutationError.emptyName }

        try await db.write { db in
            try TagMutationPolicy.assertNoActiveBatchLifecycle(db)

            guard let tag = try Tag.fetchOne(db, key: tagId) else {
                throw TagMutationError.tagNotFound
            }

            try Self.validateAliasCreation(
                normalizedAlias: normalizedAlias,
                for: tag,
                db: db
            )

            var row = TagAlias(
                id: nil,
                tagId: tagId,
                alias: trimmed,
                normalizedAlias: normalizedAlias
            )
            try row.insert(db)
        }
    }

    func deleteAlias(id: Int64) async throws {
        try await db.write { db in
            try TagMutationPolicy.assertNoActiveBatchLifecycle(db)
            try db.execute(sql: "DELETE FROM tag_alias WHERE id = ?", arguments: [id])
        }
    }

    func makeTagPermanent(id: Int64) async throws {
        try await db.write { db in
            try TagMutationPolicy.assertNoActiveBatchLifecycle(db)
            guard try Tag.fetchOne(db, key: id) != nil else {
                throw TagMutationError.tagNotFound
            }

            try db.execute(sql: "UPDATE tag SET isProvisional = 0 WHERE id = ?", arguments: [id])
        }
    }

    func deleteUnusedTags() async throws -> Int {
        try await db.write { db in
            try TagMutationPolicy.assertNoActiveBatchLifecycle(db)

            let unusedTagIDs = try Int64.fetchAll(
                db,
                sql: """
                SELECT id
                FROM tag
                WHERE usageCount = 0
                  AND id NOT IN (SELECT DISTINCT tagId FROM entry_tag)
                """
            )

            for tagID in unusedTagIDs {
                try TagMutationPolicy.deleteTagRows(id: tagID, db: db)
            }

            return unusedTagIDs.count
        }
    }

    func deleteTag(id: Int64) async throws {
        try await db.write { db in
            try TagMutationPolicy.assertNoActiveBatchLifecycle(db)
            try TagMutationPolicy.deleteTagRows(id: id, db: db)
        }
    }

    private static func validateAliasCreation(
        normalizedAlias: String,
        for tag: Tag,
        db: Database
    ) throws {
        guard let tagID = tag.id else {
            throw TagMutationError.tagNotFound
        }
        if normalizedAlias == tag.normalizedName {
            throw TagMutationError.aliasMatchesCanonicalName
        }

        let canonicalCollision = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM tag WHERE normalizedName = ? AND id != ? LIMIT 1",
            arguments: [normalizedAlias, tagID]
        )
        if canonicalCollision != nil {
            throw TagMutationError.nameAlreadyExists
        }

        let aliasCollision = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM tag_alias WHERE normalizedAlias = ? LIMIT 1",
            arguments: [normalizedAlias]
        )
        if aliasCollision != nil {
            throw TagMutationError.aliasAlreadyExists
        }
    }

    private static func canSafelyAttachAlias(
        normalizedAlias: String,
        targetTag: Tag,
        sourceTagID: Int64,
        db: Database
    ) throws -> Bool {
        guard let targetTagID = targetTag.id else { return false }
        guard normalizedAlias != targetTag.normalizedName else { return false }

        let canonicalCollision = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM tag WHERE normalizedName = ? AND id NOT IN (?, ?) LIMIT 1",
            arguments: [normalizedAlias, sourceTagID, targetTagID]
        )
        if canonicalCollision != nil {
            return false
        }

        let aliasOwner = try Row.fetchOne(
            db,
            sql: "SELECT id AS aliasId, tagId FROM tag_alias WHERE normalizedAlias = ? LIMIT 1",
            arguments: [normalizedAlias]
        )

        guard let aliasOwner else {
            return true
        }

        let ownerTagID: Int64 = aliasOwner["tagId"] ?? 0
        if ownerTagID == sourceTagID {
            return true
        }

        return false
    }

    private static func refreshUsageCount(for tagID: Int64, db: Database) throws {
        try db.execute(
            sql: """
            UPDATE tag
            SET usageCount = (
                SELECT COUNT(*)
                FROM entry_tag
                WHERE tagId = ?
            )
            WHERE id = ?
            """,
            arguments: [tagID, tagID]
        )

        try db.execute(
            sql: """
            UPDATE tag
            SET isProvisional = 0
            WHERE id = ?
              AND usageCount >= ?
            """,
            arguments: [tagID, TaggingPolicy.provisionalPromotionThreshold]
        )
    }

    private static func loadDuplicateCandidatesByTagID(
        db: Database
    ) throws -> [Int64: [TagDuplicateCandidate]] {
        let tags = try Tag
            .order(Column("normalizedName").asc)
            .fetchAll(db)

        let aliases = try TagAlias.fetchAll(db)
        var aliasesByTagID: [Int64: Set<String>] = [:]
        for alias in aliases {
            aliasesByTagID[alias.tagId, default: []].insert(alias.normalizedAlias)
        }

        var result: [Int64: [TagDuplicateCandidate]] = [:]
        guard tags.count > 1 else { return result }

        for (index, tag) in tags.enumerated() {
            guard let tagID = tag.id else { continue }
            for otherTag in tags[(index + 1)...] {
                guard let otherTagID = otherTag.id else { continue }
                guard
                    let reason = duplicateReason(
                        between: tag,
                        and: otherTag,
                        aliasesByTagID: aliasesByTagID
                    )
                else {
                    continue
                }

                result[tagID, default: []].append(
                    TagDuplicateCandidate(
                        tagId: otherTagID,
                        name: otherTag.name,
                        usageCount: otherTag.usageCount,
                        reason: reason
                    )
                )
                result[otherTagID, default: []].append(
                    TagDuplicateCandidate(
                        tagId: tagID,
                        name: tag.name,
                        usageCount: tag.usageCount,
                        reason: reason
                    )
                )
            }
        }

        for tagID in Array(result.keys) {
            result[tagID]?.sort {
                if reasonPriority($0.reason) != reasonPriority($1.reason) {
                    return reasonPriority($0.reason) < reasonPriority($1.reason)
                }
                if $0.usageCount != $1.usageCount {
                    return $0.usageCount > $1.usageCount
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }

        return result
    }

    private static func duplicateReason(
        between lhs: Tag,
        and rhs: Tag,
        aliasesByTagID: [Int64: Set<String>]
    ) -> TagDuplicateCandidate.Reason? {
        guard lhs.normalizedName != rhs.normalizedName else { return nil }
        guard let lhsID = lhs.id, let rhsID = rhs.id else { return nil }
        guard pairAlreadyAbsorbedByAlias(lhsID: lhsID, lhs: lhs, rhsID: rhsID, rhs: rhs, aliasesByTagID: aliasesByTagID) == false else {
            return nil
        }

        if isPluralizationVariant(lhs.normalizedName, rhs.normalizedName) {
            return .pluralizationVariant
        }
        if isLikelyNamingVariant(lhs.normalizedName, rhs.normalizedName) {
            return .likelyNamingVariant
        }
        if isNearSpellingVariant(lhs.normalizedName, rhs.normalizedName) {
            return .nearSpellingVariant
        }

        return nil
    }

    private static func pairAlreadyAbsorbedByAlias(
        lhsID: Int64,
        lhs: Tag,
        rhsID: Int64,
        rhs: Tag,
        aliasesByTagID: [Int64: Set<String>]
    ) -> Bool {
        let lhsAliases = aliasesByTagID[lhsID, default: []]
        let rhsAliases = aliasesByTagID[rhsID, default: []]
        return lhsAliases.contains(rhs.normalizedName) || rhsAliases.contains(lhs.normalizedName)
    }

    private static func isPluralizationVariant(_ lhs: String, _ rhs: String) -> Bool {
        let lhsTokens = lhs.split(separator: " ").map(String.init)
        let rhsTokens = rhs.split(separator: " ").map(String.init)
        guard lhsTokens.count == rhsTokens.count, lhsTokens.isEmpty == false else { return false }
        guard lhsTokens != rhsTokens else { return false }
        return lhsTokens.map(singularizeToken) == rhsTokens.map(singularizeToken)
    }

    private static func isNearSpellingVariant(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.contains(" ") == false, rhs.contains(" ") == false else { return false }
        guard min(lhs.count, rhs.count) >= 5 else { return false }
        guard lhs.first == rhs.first, lhs.last == rhs.last else { return false }
        return TagInputSuggestionEngine.editDistance(lhs, rhs) <= 2
    }

    private static func isLikelyNamingVariant(_ lhs: String, _ rhs: String) -> Bool {
        let lhsCompacted = lhs.replacingOccurrences(of: " ", with: "")
        let rhsCompacted = rhs.replacingOccurrences(of: " ", with: "")

        if lhsCompacted == rhsCompacted {
            return lhs != rhs
        }

        guard min(lhsCompacted.count, rhsCompacted.count) >= 6 else { return false }
        guard lhsCompacted.first == rhsCompacted.first else { return false }
        return TagInputSuggestionEngine.editDistance(lhsCompacted, rhsCompacted) == 1
    }

    private static func singularizeToken(_ token: String) -> String {
        guard token.count >= 4 else { return token }

        if token.hasSuffix("ies"), token.count > 4 {
            return String(token.dropLast(3)) + "y"
        }

        for suffix in ["sses", "shes", "ches", "xes", "zes", "oes"] {
            if token.hasSuffix(suffix) {
                return String(token.dropLast(2))
            }
        }

        if token.hasSuffix("s"), token.hasSuffix("ss") == false {
            return String(token.dropLast())
        }

        return token
    }

    private static func reasonPriority(_ reason: TagDuplicateCandidate.Reason) -> Int {
        switch reason {
        case .pluralizationVariant:
            return 0
        case .likelyNamingVariant:
            return 1
        case .nearSpellingVariant:
            return 2
        }
    }
}
