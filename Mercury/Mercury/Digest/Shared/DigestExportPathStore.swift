import Foundation

enum DigestExportPathStore {
    private static let exportDirectoryBookmarkKey = "Digest.LocalExportDirectoryBookmark"

    static func saveDirectory(_ url: URL) {
        SecurityScopedBookmarkStore.saveDirectory(url, key: exportDirectoryBookmarkKey)
    }

    static func resolveDirectory() -> URL? {
        SecurityScopedBookmarkStore.resolveDirectory(key: exportDirectoryBookmarkKey)
    }

    static func clearDirectory() {
        SecurityScopedBookmarkStore.clearDirectory(key: exportDirectoryBookmarkKey)
    }

    static func isConfiguredDirectoryAvailable(fileManager: FileManager = .default) -> Bool {
        guard let directory = resolveDirectory() else {
            return false
        }

        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
