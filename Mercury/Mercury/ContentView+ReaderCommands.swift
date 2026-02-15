import SwiftUI

extension ContentView {
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
        readerThemeOverrideLineHeight = 0
        readerThemeOverrideContentWidth = 0
        readerThemeOverrideFontFamilyRaw = ReaderThemeFontFamilyOptionID.usePreset.rawValue
        readerThemeQuickStylePresetIDRaw = ReaderThemeQuickStylePresetID.none.rawValue
    }
}
