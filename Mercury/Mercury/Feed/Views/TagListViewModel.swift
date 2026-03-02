import Foundation
import Combine

@MainActor
final class TagListViewModel: ObservableObject {
    @Published private(set) var tags: [Tag] = []
    @Published var searchText: String = ""
    @Published private(set) var isLoading = false

    private let entryStore: EntryStore

    init(entryStore: EntryStore) {
        self.entryStore = entryStore
    }

    func loadNonProvisionalTags() async {
        isLoading = true
        defer { isLoading = false }
        tags = await entryStore.fetchTags(includeProvisional: false, searchText: searchText)
    }
}
