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

    func decreaseReaderFontSize() {
        guard selectedEntryDetail != nil else { return }
        let current = readerThemeOverrideFontSize > 0 ? readerThemeOverrideFontSize : ReaderThemeRules.defaultFontSizeFallback
        readerThemeOverrideFontSize = ReaderThemeRules.clampFontSize(current - 1)
    }

    func increaseReaderFontSize() {
        guard selectedEntryDetail != nil else { return }
        let current = readerThemeOverrideFontSize > 0 ? readerThemeOverrideFontSize : ReaderThemeRules.defaultFontSizeFallback
        readerThemeOverrideFontSize = ReaderThemeRules.clampFontSize(current + 1)
    }

    func resetReaderOverrides() {
        guard selectedEntryDetail != nil else { return }
        let reset = ReaderThemeRules.resetOverrideStorage
        readerThemeOverrideFontSize = reset.fontSizeOverride
        readerThemeOverrideLineHeight = reset.lineHeightOverride
        readerThemeOverrideContentWidth = reset.contentWidthOverride
        readerThemeOverrideFontFamilyRaw = reset.fontFamilyOptionRaw
        readerThemeQuickStylePresetIDRaw = reset.quickStylePresetRaw
    }
}