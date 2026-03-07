import Combine
import Foundation

struct TagLibrarySheetMessage: Identifiable, Equatable {
    enum Tone: Equatable {
        case success
        case warning
        case error
    }

    let id = UUID()
    let tone: Tone
    let text: String
}

@MainActor
final class TagLibraryViewModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var filter: TagLibraryFilter = .all
    @Published var pendingAliasText: String = ""

    @Published private(set) var items: [TagLibraryListItem] = []
    @Published private(set) var selectedTagID: Int64?
    @Published private(set) var inspector: TagLibraryInspectorSnapshot?
    @Published private(set) var totalTagCount: Int = 0
    @Published private(set) var provisionalCount: Int = 0
    @Published private(set) var unusedCount: Int = 0
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isMutationAllowed: Bool = true
    @Published var message: TagLibrarySheetMessage?

    private weak var appModel: AppModel?
    private var allItems: [TagLibraryListItem] = []
    private var refreshGeneration: Int = 0

    var isLibraryEmpty: Bool {
        allItems.isEmpty
    }

    var hasSelection: Bool {
        inspector != nil
    }

    var selectedTagName: String? {
        inspector?.name
    }

    var canAddAlias: Bool {
        inspector != nil && isMutationAllowed
    }

    var canMergeSelectedTag: Bool {
        inspector != nil && mergeTargetItems.isEmpty == false && isMutationAllowed
    }

    var canMakeSelectedTagPermanent: Bool {
        inspector?.isProvisional == true && isMutationAllowed
    }

    var canDeleteSelectedTag: Bool {
        inspector != nil && isMutationAllowed
    }

    var canDeleteUnusedTags: Bool {
        unusedCount > 0 && isMutationAllowed
    }

    var mergeTargetItems: [TagLibraryListItem] {
        guard let selectedTagID else { return [] }
        return allItems.filter { $0.tagId != selectedTagID }
    }

    func mergeTargets(matching searchText: String) -> [TagLibraryListItem] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSearchText.isEmpty == false else {
            return mergeTargetItems
        }

        return mergeTargetItems.filter { item in
            item.name.localizedCaseInsensitiveContains(trimmedSearchText)
                || item.normalizedName.localizedCaseInsensitiveContains(trimmedSearchText)
        }
    }

    func bindIfNeeded(appModel: AppModel) async {
        guard self.appModel == nil else { return }
        self.appModel = appModel
        await refresh()
    }

    func refresh() async {
        guard let appModel else { return }

        let generation = refreshGeneration + 1
        refreshGeneration = generation
        isLoading = true

        let currentSelection = selectedTagID
        let items = await appModel.loadTagLibraryItems(
            filter: filter,
            searchText: searchText
        )
        let allItems = await appModel.loadTagLibraryItems(filter: .all)

        let nextSelectedTagID = resolveSelection(
            currentSelection: currentSelection,
            visibleItems: items
        )
        let inspector: TagLibraryInspectorSnapshot? = if let nextSelectedTagID {
            await appModel.loadTagLibraryInspectorSnapshot(tagId: nextSelectedTagID)
        } else {
            nil
        }

        let mutationAvailabilitySnapshot: TagLibraryInspectorSnapshot?
        if let inspector {
            mutationAvailabilitySnapshot = inspector
        } else if let fallbackTagID = allItems.first?.tagId {
            mutationAvailabilitySnapshot = await appModel.loadTagLibraryInspectorSnapshot(tagId: fallbackTagID)
        } else {
            mutationAvailabilitySnapshot = nil
        }

        guard generation == refreshGeneration else { return }

        self.items = items
        self.allItems = allItems
        selectedTagID = inspector?.tagId
        self.inspector = inspector
        totalTagCount = allItems.count
        provisionalCount = allItems.filter(\.isProvisional).count
        unusedCount = allItems.filter { $0.usageCount == 0 }.count
        isMutationAllowed = mutationAvailabilitySnapshot?.isMutationAllowed ?? true
        isLoading = false
    }

    func selectTag(id: Int64?) async {
        guard let appModel else { return }
        guard selectedTagID != id else { return }

        selectedTagID = id
        if let id {
            inspector = await appModel.loadTagLibraryInspectorSnapshot(tagId: id)
            isMutationAllowed = inspector?.isMutationAllowed ?? true
        } else {
            inspector = nil
            if let fallbackTagID = allItems.first?.tagId {
                let snapshot = await appModel.loadTagLibraryInspectorSnapshot(tagId: fallbackTagID)
                isMutationAllowed = snapshot?.isMutationAllowed ?? true
            } else {
                isMutationAllowed = true
            }
        }
    }

    func loadMergePreview(targetID: Int64) async -> TagLibraryMergePreview? {
        guard let appModel, let sourceID = inspector?.tagId else { return nil }

        do {
            return try await appModel.loadTagLibraryMergePreview(
                sourceID: sourceID,
                targetID: targetID
            )
        } catch {
            presentMutationError(
                error,
                fallback: String(localized: "Failed to prepare tag merge.", bundle: bundle)
            )
            return nil
        }
    }

    func addAlias() async {
        guard let appModel, let tagID = inspector?.tagId else { return }

        do {
            try await appModel.addTagLibraryAlias(tagId: tagID, alias: pendingAliasText)
            pendingAliasText = ""
            message = TagLibrarySheetMessage(
                tone: .success,
                text: String(localized: "Alias added.", bundle: bundle)
            )
            await refresh()
        } catch {
            presentMutationError(
                error,
                fallback: String(localized: "Failed to add alias.", bundle: bundle)
            )
        }
    }

    func deleteAlias(id: Int64) async {
        guard let appModel else { return }

        do {
            try await appModel.deleteTagLibraryAlias(id: id)
            message = TagLibrarySheetMessage(
                tone: .success,
                text: String(localized: "Alias deleted.", bundle: bundle)
            )
            await refresh()
        } catch {
            presentMutationError(
                error,
                fallback: String(localized: "Failed to delete alias.", bundle: bundle)
            )
        }
    }

    func mergeSelectedTag(into targetID: Int64) async {
        guard let appModel, let sourceID = inspector?.tagId else { return }

        do {
            try await appModel.mergeTagLibraryTag(sourceID: sourceID, targetID: targetID)
            message = TagLibrarySheetMessage(
                tone: .success,
                text: String(localized: "Tags merged.", bundle: bundle)
            )
            await refresh()
        } catch {
            presentMutationError(
                error,
                fallback: String(localized: "Failed to merge tags.", bundle: bundle)
            )
        }
    }

    func makeSelectedTagPermanent() async {
        guard let appModel, let tagID = inspector?.tagId else { return }

        do {
            try await appModel.makeTagLibraryTagPermanent(id: tagID)
            message = TagLibrarySheetMessage(
                tone: .success,
                text: String(localized: "Tag marked permanent.", bundle: bundle)
            )
            await refresh()
        } catch {
            presentMutationError(
                error,
                fallback: String(localized: "Failed to update tag.", bundle: bundle)
            )
        }
    }

    func deleteSelectedTag() async {
        guard let appModel, let tagID = inspector?.tagId else { return }

        do {
            try await appModel.deleteTagLibraryTag(id: tagID)
            message = TagLibrarySheetMessage(
                tone: .success,
                text: String(localized: "Tag deleted.", bundle: bundle)
            )
            await refresh()
        } catch {
            presentMutationError(
                error,
                fallback: String(localized: "Failed to delete tag.", bundle: bundle)
            )
        }
    }

    func deleteUnusedTags() async {
        guard let appModel else { return }

        do {
            let deletedCount = try await appModel.deleteUnusedTagLibraryTags()
            message = TagLibrarySheetMessage(
                tone: deletedCount > 0 ? .success : .warning,
                text: deletedCount > 0
                    ? String(
                        format: String(localized: "Deleted %lld unused tags.", bundle: bundle),
                        Int64(deletedCount)
                    )
                    : String(localized: "No unused tags to delete.", bundle: bundle)
            )
            await refresh()
        } catch {
            presentMutationError(
                error,
                fallback: String(localized: "Failed to delete unused tags.", bundle: bundle)
            )
        }
    }

    func clearMessage() {
        message = nil
    }

    private func presentMutationError(_ error: Error, fallback: String) {
        let text: String

        switch error {
        case TagMutationError.emptyName:
            text = String(localized: "Name cannot be empty.", bundle: bundle)
        case TagMutationError.nameAlreadyExists:
            text = String(localized: "This name already exists.", bundle: bundle)
        case TagMutationError.aliasAlreadyExists:
            text = String(localized: "This alias already exists.", bundle: bundle)
        case TagMutationError.aliasMatchesCanonicalName:
            text = String(localized: "Alias matches the canonical tag name.", bundle: bundle)
        case TagMutationError.batchRunActive:
            text = String(localized: "Tag library mutations are unavailable while batch tagging is active.", bundle: bundle)
        case TagMutationError.tagNotFound:
            text = String(localized: "The selected tag no longer exists.", bundle: bundle)
        case TagMutationError.cannotMergeIntoSelf:
            text = String(localized: "Choose a different target tag.", bundle: bundle)
        default:
            text = fallback
        }

        message = TagLibrarySheetMessage(tone: .error, text: text)
    }

    private func resolveSelection(
        currentSelection: Int64?,
        visibleItems: [TagLibraryListItem]
    ) -> Int64? {
        guard visibleItems.isEmpty == false else { return nil }

        if let currentSelection, visibleItems.contains(where: { $0.tagId == currentSelection }) {
            return currentSelection
        }

        return visibleItems.first?.tagId
    }

    private var bundle: Bundle {
        LanguageManager.shared.bundle
    }
}
