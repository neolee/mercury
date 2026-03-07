//
//  AppModel+TagLibrary.swift
//  Mercury
//

import Foundation

extension AppModel {
    func loadTagLibraryItems(
        filter: TagLibraryFilter,
        searchText: String? = nil
    ) async -> [TagLibraryListItem] {
        await TagLibraryStore(db: database).fetchTagLibraryItems(
            filter: filter,
            searchText: searchText
        )
    }

    func loadTagLibraryInspectorSnapshot(tagId: Int64) async -> TagLibraryInspectorSnapshot? {
        await TagLibraryStore(db: database).loadInspectorSnapshot(tagId: tagId)
    }

    func loadTagLibraryMergePreview(
        sourceID: Int64,
        targetID: Int64
    ) async throws -> TagLibraryMergePreview {
        try await TagLibraryStore(db: database).loadMergePreview(sourceID: sourceID, targetID: targetID)
    }

    func mergeTagLibraryTag(sourceID: Int64, targetID: Int64) async throws {
        try await TagLibraryStore(db: database).mergeTag(sourceID: sourceID, targetID: targetID)
        tagMutationVersion += 1
    }

    func addTagLibraryAlias(tagId: Int64, alias: String) async throws {
        try await TagLibraryStore(db: database).addAlias(tagId: tagId, alias: alias)
        tagMutationVersion += 1
    }

    func deleteTagLibraryAlias(id: Int64) async throws {
        try await TagLibraryStore(db: database).deleteAlias(id: id)
        tagMutationVersion += 1
    }

    func makeTagLibraryTagPermanent(id: Int64) async throws {
        try await TagLibraryStore(db: database).makeTagPermanent(id: id)
        tagMutationVersion += 1
    }

    func deleteTagLibraryTag(id: Int64) async throws {
        try await TagLibraryStore(db: database).deleteTag(id: id)
        tagMutationVersion += 1
    }

    @discardableResult
    func deleteUnusedTagLibraryTags() async throws -> Int {
        let deletedCount = try await TagLibraryStore(db: database).deleteUnusedTags()
        if deletedCount > 0 {
            tagMutationVersion += 1
        }
        return deletedCount
    }
}
