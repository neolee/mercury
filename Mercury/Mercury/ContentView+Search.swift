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

    func decreaseReaderPreviewFontSize() {
        guard selectedEntryDetail != nil else { return }
        let current = readerThemeOverrideFontSize > 0 ? readerThemeOverrideFontSize : 17
        readerThemeOverrideFontSize = max(13, current - 1)
    }

    func increaseReaderPreviewFontSize() {
        guard selectedEntryDetail != nil else { return }
        let current = readerThemeOverrideFontSize > 0 ? readerThemeOverrideFontSize : 17
        readerThemeOverrideFontSize = min(28, current + 1)
    }

    func resetReaderPreviewOverrides() {
        guard selectedEntryDetail != nil else { return }
        readerThemeOverrideFontSize = 0
        readerThemeOverrideFontFamilyRaw = ReaderThemeFontFamilyOptionID.usePreset.rawValue
        readerThemeQuickStylePresetIDRaw = ReaderThemeQuickStylePresetID.none.rawValue
    }
}
