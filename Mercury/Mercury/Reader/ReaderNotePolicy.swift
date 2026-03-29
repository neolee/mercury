import Foundation

enum ReaderNotePolicy {
    static let autoFlushDelay: Duration = .seconds(5)

    static let editorMinHeight: CGFloat = 140
    static let editorMaxHeight: CGFloat = 240
    static let editorGrowthThresholdHeight: CGFloat = 180
}
