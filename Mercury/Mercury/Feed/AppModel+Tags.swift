//
//  AppModel+Tags.swift
//  Mercury
//

import Foundation

extension AppModel {

    // MARK: - Tag Management

    /// Renames a tag to a new display name.
    ///
    /// Silently ignored when `newName` is blank or already taken by another tag.
    func renameTag(id: Int64, newName: String) async {
        do {
            try await entryStore.renameTag(id: id, newName: newName)
            tagMutationVersion += 1
        } catch TagMutationError.emptyName {
            // Blank name — no-op; the UI validates before calling.
        } catch TagMutationError.nameAlreadyExists {
            // Collision — no-op for now; surfaced via UI affordance in a future pass.
        } catch {
            print("[AppModel] renameTag failed: \(error)")
        }
    }

    /// Deletes a tag and removes it from all articles.
    func deleteTag(id: Int64) async {
        do {
            try await entryStore.deleteTag(id: id)
            tagMutationVersion += 1
        } catch {
            print("[AppModel] deleteTag failed: \(error)")
        }
    }
}
