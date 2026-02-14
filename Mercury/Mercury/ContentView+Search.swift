import AppKit
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

    func installLocalKeyboardMonitorIfNeeded() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if modifiers.contains(.command),
               modifiers.contains(.option) == false,
               modifiers.contains(.control) == false,
               modifiers.contains(.shift) == false,
               (event.keyCode == 3 || event.charactersIgnoringModifiers?.lowercased() == "f") {
                focusSearchFieldDeferred()
                return nil
            }

            if event.keyCode == 53, (isSearchFieldFocused || searchText.isEmpty == false) {
                clearAndBlurSearchField()
                return nil
            }

            return event
        }
    }

    func removeLocalKeyboardMonitor() {
        guard let localKeyMonitor else { return }
        NSEvent.removeMonitor(localKeyMonitor)
        self.localKeyMonitor = nil
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
