import Darwin
import Foundation

nonisolated enum DigestExportDirectoryIssue: Equatable, Sendable {
    case bookmarkMissing
    case bookmarkResolveFailed
    case directoryMissing
    case invalidDirectory
    case accessDenied
    case writeProbeFailed

    nonisolated func localizedRecoveryMessage(bundle: Bundle) -> String {
        switch self {
        case .bookmarkMissing:
            return String(
                localized: "Digest export needs a valid local export folder. Configure it in Settings > Digest.",
                bundle: bundle
            )
        case .bookmarkResolveFailed:
            return String(
                localized: "Digest export folder access has expired. Re-select it in Settings > Digest.",
                bundle: bundle
            )
        case .directoryMissing:
            return String(
                localized: "Digest export folder no longer exists. Re-select it in Settings > Digest.",
                bundle: bundle
            )
        case .invalidDirectory:
            return String(
                localized: "Digest export folder is invalid. Re-select it in Settings > Digest.",
                bundle: bundle
            )
        case .accessDenied:
            return String(
                localized: "Digest export folder access has expired. Re-select it in Settings > Digest.",
                bundle: bundle
            )
        case .writeProbeFailed:
            return String(
                localized: "Digest export folder access check failed. Re-select it in Settings > Digest.",
                bundle: bundle
            )
        }
    }

    nonisolated func localizedStatusText(bundle: Bundle) -> String {
        switch self {
        case .bookmarkMissing:
            return String(localized: "Not configured", bundle: bundle)
        case .bookmarkResolveFailed, .accessDenied:
            return String(localized: "Access expired", bundle: bundle)
        case .directoryMissing:
            return String(localized: "Missing", bundle: bundle)
        case .invalidDirectory:
            return String(localized: "Invalid folder", bundle: bundle)
        case .writeProbeFailed:
            return String(localized: "Access check failed", bundle: bundle)
        }
    }
}

nonisolated struct DigestExportDirectoryDiagnostic: Equatable, Sendable {
    let bookmarkStored: Bool
    let resolvedURL: URL?
    let bookmarkWasStale: Bool
    let directoryExists: Bool
    let isDirectory: Bool
    let startAccessingSucceeded: Bool?
    let writeProbeSucceeded: Bool?
    let issue: DigestExportDirectoryIssue?
    let underlyingErrorDescription: String?

    nonisolated var resolvedPath: String? {
        resolvedURL?.path
    }

    nonisolated func debugLines(operation: String, preferredFileName: String? = nil) -> [String] {
        var lines: [String] = [
            "operation=\(operation)",
            "bookmarkStored=\(bookmarkStored)",
            "resolvedPath=\(resolvedPath ?? "(nil)")",
            "bookmarkWasStale=\(bookmarkWasStale)",
            "directoryExists=\(directoryExists)",
            "isDirectory=\(isDirectory)",
            "startAccessingSucceeded=\(startAccessingSucceeded.map { String($0) } ?? "(nil)")",
            "writeProbeSucceeded=\(writeProbeSucceeded.map { String($0) } ?? "(nil)")",
            "issue=\(issue.map { String(describing: $0) } ?? "ready")"
        ]

        if let preferredFileName {
            lines.append("preferredFileName=\(preferredFileName)")
        }
        if let underlyingErrorDescription {
            lines.append("underlyingError=\(underlyingErrorDescription)")
        }
        return lines
    }
}

nonisolated struct DigestExportDirectoryStatus: Equatable, Sendable {
    let diagnostic: DigestExportDirectoryDiagnostic

    static let notConfigured = DigestExportDirectoryStatus(
        diagnostic: DigestExportDirectoryDiagnostic(
            bookmarkStored: false,
            resolvedURL: nil,
            bookmarkWasStale: false,
            directoryExists: false,
            isDirectory: false,
            startAccessingSucceeded: nil,
            writeProbeSucceeded: nil,
            issue: .bookmarkMissing,
            underlyingErrorDescription: nil
        )
    )

    nonisolated var issue: DigestExportDirectoryIssue? {
        diagnostic.issue
    }

    nonisolated var resolvedURL: URL? {
        diagnostic.resolvedURL
    }

    nonisolated var path: String {
        diagnostic.resolvedPath ?? ""
    }

    nonisolated var isAvailable: Bool {
        issue == nil
    }

    nonisolated var canRevealInFinder: Bool {
        guard let resolvedURL else { return false }
        switch issue {
        case .bookmarkMissing, .bookmarkResolveFailed, .directoryMissing:
            return false
        case .invalidDirectory, .accessDenied, .writeProbeFailed, .none:
            return FileManager.default.fileExists(atPath: resolvedURL.path)
        }
    }

    nonisolated func localizedRecoveryMessage(bundle: Bundle) -> String? {
        issue?.localizedRecoveryMessage(bundle: bundle)
    }

    nonisolated func localizedStatusText(bundle: Bundle) -> String {
        guard let issue else {
            return String(localized: "Available", bundle: bundle)
        }
        return issue.localizedStatusText(bundle: bundle)
    }
}

nonisolated enum DigestExportPathStore {
    private static let exportDirectoryBookmarkKey = "Digest.LocalExportDirectoryBookmark"

    typealias BookmarkResolver = (_ key: String) -> SecurityScopedBookmarkResolutionResult
    typealias Accessor = (_ url: URL, _ work: @escaping () throws -> Void) throws -> Void
    typealias ProbeWriter = (_ directory: URL, _ fileManager: FileManager) throws -> Void

    nonisolated static func saveDirectory(_ url: URL) {
        SecurityScopedBookmarkStore.saveDirectory(url, key: exportDirectoryBookmarkKey)
    }

    nonisolated static func resolveDirectory() -> URL? {
        SecurityScopedBookmarkStore.resolveDirectory(key: exportDirectoryBookmarkKey)
    }

    nonisolated static func clearDirectory() {
        SecurityScopedBookmarkStore.clearDirectory(key: exportDirectoryBookmarkKey)
    }

    nonisolated static func isConfiguredDirectoryAvailable(fileManager: FileManager = .default) -> Bool {
        currentDirectoryStatus(fileManager: fileManager).isAvailable
    }

    nonisolated static func currentDirectoryStatus(
        fileManager: FileManager = .default,
        bookmarkResolver: BookmarkResolver = { SecurityScopedBookmarkStore.resolveDirectoryStatus(key: $0) },
        accessor: @escaping Accessor = { url, work in try SecurityScopedBookmarkStore.access(url, work) },
        probeWriter: @escaping ProbeWriter = defaultWriteProbe
    ) -> DigestExportDirectoryStatus {
        switch bookmarkResolver(exportDirectoryBookmarkKey) {
        case .missing:
            return .notConfigured
        case let .failed(errorDescription):
            return DigestExportDirectoryStatus(
                diagnostic: DigestExportDirectoryDiagnostic(
                    bookmarkStored: true,
                    resolvedURL: nil,
                    bookmarkWasStale: false,
                    directoryExists: false,
                    isDirectory: false,
                    startAccessingSucceeded: nil,
                    writeProbeSucceeded: nil,
                    issue: .bookmarkResolveFailed,
                    underlyingErrorDescription: errorDescription
                )
            )
        case let .resolved(url, wasStale):
            return inspectResolvedDirectory(
                url,
                bookmarkWasStale: wasStale,
                fileManager: fileManager,
                accessor: accessor,
                probeWriter: probeWriter
            )
        }
    }

    nonisolated private static func inspectResolvedDirectory(
        _ url: URL,
        bookmarkWasStale: Bool,
        fileManager: FileManager,
        accessor: @escaping Accessor,
        probeWriter: @escaping ProbeWriter
    ) -> DigestExportDirectoryStatus {
        var isDirectory: ObjCBool = false
        let directoryExists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)

        guard directoryExists else {
            return DigestExportDirectoryStatus(
                diagnostic: DigestExportDirectoryDiagnostic(
                    bookmarkStored: true,
                    resolvedURL: url,
                    bookmarkWasStale: bookmarkWasStale,
                    directoryExists: false,
                    isDirectory: false,
                    startAccessingSucceeded: nil,
                    writeProbeSucceeded: nil,
                    issue: .directoryMissing,
                    underlyingErrorDescription: nil
                )
            )
        }

        guard isDirectory.boolValue else {
            return DigestExportDirectoryStatus(
                diagnostic: DigestExportDirectoryDiagnostic(
                    bookmarkStored: true,
                    resolvedURL: url,
                    bookmarkWasStale: bookmarkWasStale,
                    directoryExists: true,
                    isDirectory: false,
                    startAccessingSucceeded: nil,
                    writeProbeSucceeded: nil,
                    issue: .invalidDirectory,
                    underlyingErrorDescription: nil
                )
            )
        }

        do {
            try accessor(url) {
                try probeWriter(url, fileManager)
            }
            return DigestExportDirectoryStatus(
                diagnostic: DigestExportDirectoryDiagnostic(
                    bookmarkStored: true,
                    resolvedURL: url,
                    bookmarkWasStale: bookmarkWasStale,
                    directoryExists: true,
                    isDirectory: true,
                    startAccessingSucceeded: true,
                    writeProbeSucceeded: true,
                    issue: nil,
                    underlyingErrorDescription: nil
                )
            )
        } catch let error as SecurityScopedBookmarkAccessError {
            return DigestExportDirectoryStatus(
                diagnostic: DigestExportDirectoryDiagnostic(
                    bookmarkStored: true,
                    resolvedURL: url,
                    bookmarkWasStale: bookmarkWasStale,
                    directoryExists: true,
                    isDirectory: true,
                    startAccessingSucceeded: false,
                    writeProbeSucceeded: nil,
                    issue: .accessDenied,
                    underlyingErrorDescription: error.localizedDescription
                )
            )
        } catch {
            return DigestExportDirectoryStatus(
                diagnostic: DigestExportDirectoryDiagnostic(
                    bookmarkStored: true,
                    resolvedURL: url,
                    bookmarkWasStale: bookmarkWasStale,
                    directoryExists: true,
                    isDirectory: true,
                    startAccessingSucceeded: true,
                    writeProbeSucceeded: false,
                    issue: isPermissionDenied(error) ? .accessDenied : .writeProbeFailed,
                    underlyingErrorDescription: error.localizedDescription
                )
            )
        }
    }

    nonisolated private static func defaultWriteProbe(_ directory: URL, _ fileManager: FileManager) throws {
        let probeURL = directory.appendingPathComponent(".mercury-export-access-\(UUID().uuidString).tmp", isDirectory: false)
        let data = Data()
        try data.write(to: probeURL, options: .atomic)
        if fileManager.fileExists(atPath: probeURL.path) {
            try fileManager.removeItem(at: probeURL)
        }
    }

    nonisolated private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == EACCES || nsError.code == EPERM
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionDenied(underlying)
        }
        return false
    }
}
