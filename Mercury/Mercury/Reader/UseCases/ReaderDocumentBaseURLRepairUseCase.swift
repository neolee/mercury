import Foundation

@MainActor
struct ReaderDocumentBaseURLRepairUseCase {
    typealias ArticleURLPreparer = @MainActor (Entry, ((String) -> Void)?) async -> ReaderArticleURLPreparation?
    typealias SourceDocumentFetcher = @MainActor (URL, @escaping (String) -> Void) async throws -> ReaderFetchedDocument

    let contentStore: ContentStore
    let prepareArticleURL: ArticleURLPreparer
    let sourceDocumentFetcher: SourceDocumentFetcher

    init(
        contentStore: ContentStore,
        prepareArticleURL: @escaping ArticleURLPreparer,
        sourceDocumentFetcher: @escaping SourceDocumentFetcher
    ) {
        self.contentStore = contentStore
        self.prepareArticleURL = prepareArticleURL
        self.sourceDocumentFetcher = sourceDocumentFetcher
    }

    func repairIfNeeded(
        for entry: Entry,
        appendEvent: ((String) -> Void)? = nil
    ) async throws -> Bool {
        guard let entryId = entry.id else {
            return false
        }

        guard var content = try await contentStore.content(for: entryId),
              let sourceHtml = content.html,
              sourceHtml.isEmpty == false,
              content.documentBaseURL == nil else {
            return false
        }

        if let trustedStoredBaseURL = ReaderDocumentBaseURLResolver.trustedPersistedBaseURL(from: sourceHtml) {
            appendEvent?("[repair] backfilled document base URL from stored HTML")
            content.documentBaseURL = trustedStoredBaseURL.absoluteString
            content.readabilityVersion = nil
            _ = try await contentStore.upsert(content)
            return true
        }

        guard let articleURL = await prepareArticleURL(entry, appendEvent) else {
            return false
        }

        let fetchedDocument = try await sourceDocumentFetcher(articleURL.url) { event in
            appendEvent?(event)
        }
        guard let resolvedBaseURL = ReaderDocumentBaseURLResolver.resolve(
            html: fetchedDocument.html,
            responseURL: fetchedDocument.responseURL,
            fallbackURL: articleURL.url
        ), resolvedBaseURL.isPersistable else {
            appendEvent?("[repair] failed to recover a trusted document base URL")
            return false
        }

        appendEvent?("[repair] refreshed source document and recovered document base URL")
        content.html = fetchedDocument.html
        content.documentBaseURL = resolvedBaseURL.url.absoluteString
        content.readabilityVersion = nil
        _ = try await contentStore.upsert(content)
        return true
    }
}
