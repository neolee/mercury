import SwiftUI

extension ContentView {
    var searchScopeBinding: Binding<EntrySearchScope> {
        Binding(
            get: { selectedFeedId == nil ? .allFeeds : searchScope },
            set: { newValue in
                if selectedFeedId == nil {
                    searchScope = .allFeeds
                    return
                }
                searchScope = newValue
                preferredSearchScopeForFeed = newValue
                Task {
                    await loadEntries(
                        for: selectedFeedId,
                        unreadOnly: showUnreadOnly,
                        keepEntryId: nil,
                        selectFirst: true
                    )
                }
            }
        )
    }

    func focusSearchFieldDeferred() {
        DispatchQueue.main.async {
            isSearchFieldFocused = true
        }
    }

    func clearAndBlurSearchField() {
        searchText = ""
        DispatchQueue.main.async {
            isSearchFieldFocused = false
        }
    }
}
