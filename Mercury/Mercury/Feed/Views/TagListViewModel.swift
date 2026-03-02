import Foundation
import Combine

@MainActor
final class TagListViewModel: ObservableObject {
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var unreadCounts: [Int64: Int] = [:]
    @Published var searchText: String = ""
    @Published private(set) var isLoading = false

    private let entryStore: EntryStore
    private let provisionalHiddenThreshold = 30

    init(entryStore: EntryStore) {
        self.entryStore = entryStore
    }

    func loadNonProvisionalTags() async {
        isLoading = true
        defer { isLoading = false }

        let allTags = await entryStore.fetchTags(includeProvisional: true)
        let loadedTags = await entryStore.fetchTags(includeProvisional: true, searchText: searchText)
        if allTags.count > provisionalHiddenThreshold {
            tags = loadedTags.filter { $0.isProvisional == false }
        } else {
            tags = loadedTags
        }

        let visibleTagIds = tags.compactMap(\.id)
        unreadCounts = await entryStore.fetchUnreadCountByTagIds(visibleTagIds)
    }
}
