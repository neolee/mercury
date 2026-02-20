import Foundation

enum TranslationModePolicy {
    static func toggledMode(from current: TranslationMode) -> TranslationMode {
        switch current {
        case .original:
            return .bilingual
        case .bilingual:
            return .original
        }
    }

    static func toolbarButtonIconName(for mode: TranslationMode) -> String {
        switch mode {
        case .original:
            return "globe"
        case .bilingual:
            return "globe.badge.chevron.backward"
        }
    }

    static func isToolbarButtonVisible(readingMode: ReadingMode) -> Bool {
        readingMode == .reader
    }
}
