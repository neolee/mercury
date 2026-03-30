import Foundation

nonisolated struct ReaderFetchedDocument: Sendable {
    let html: String
    let responseURL: URL?
}

nonisolated enum ReaderDocumentBaseURLSource: Equatable, Sendable {
    case htmlBaseElement
    case responseURL
    case entryURLFallback
}

nonisolated struct ReaderResolvedDocumentBaseURL: Sendable {
    let url: URL
    let source: ReaderDocumentBaseURLSource
    let isPersistable: Bool
}
