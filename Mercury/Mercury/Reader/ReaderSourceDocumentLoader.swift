import Foundation

private final class ReaderSourceDocumentFetchHost: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onUpgrade: @Sendable (URL, URL) -> Void
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(onUpgrade: @escaping @Sendable (URL, URL) -> Void) {
        self.onUpgrade = onUpgrade
    }

    deinit {
        session.invalidateAndCancel()
    }

    func fetch(url: URL) async throws -> ReaderFetchedDocument {
        let (data, response) = try await session.data(from: url)
        let html: String
        if let decoded = String(data: data, encoding: .utf8) {
            html = decoded
        } else {
            html = String(decoding: data, as: UTF8.self)
        }
        return ReaderFetchedDocument(html: html, responseURL: response.url)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let originalURL = task.currentRequest?.url ?? task.originalRequest?.url
        guard let upgradedRequest = ReaderFetchRedirectPolicy.upgradedRedirectRequest(
            originalURL: originalURL,
            redirectRequest: request
        ) else {
            completionHandler(request)
            return
        }

        if let redirectURL = request.url, let upgradedURL = upgradedRequest.url {
            onUpgrade(redirectURL, upgradedURL)
        }
        completionHandler(upgradedRequest)
    }
}

struct ReaderSourceDocumentLoader {
    let jobRunner: JobRunner

    @MainActor
    func fetch(url: URL, appendEvent: @escaping ReaderEventSink) async throws -> ReaderFetchedDocument {
        let fetchHost = ReaderSourceDocumentFetchHost { redirectURL, upgradedURL in
            Task { await appendEvent("[redirect] upgraded \(redirectURL.absoluteString) -> \(upgradedURL.absoluteString)") }
        }
        return try await jobRunner.run(label: "fetchHTML", timeout: 12, onEvent: { event in
            Task { await appendEvent("[\(event.label)] \(event.message)") }
        }) { report in
            let document = try await fetchHost.fetch(url: url)
            report("decoded")
            return document
        }
    }
}
