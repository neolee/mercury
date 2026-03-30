import Foundation

private final class ReaderSourceDocumentRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let onUpgrade: @Sendable (URL, URL) -> Void

    init(onUpgrade: @escaping @Sendable (URL, URL) -> Void) {
        self.onUpgrade = onUpgrade
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
    func fetch(url: URL, appendEvent: @escaping (String) -> Void) async throws -> ReaderFetchedDocument {
        try await jobRunner.run(label: "fetchHTML", timeout: 12, onEvent: { event in
            Task { @MainActor in appendEvent("[\(event.label)] \(event.message)") }
        }) { report in
            let delegate = ReaderSourceDocumentRedirectDelegate { redirectURL, upgradedURL in
                Task { @MainActor in
                    appendEvent("[redirect] upgraded \(redirectURL.absoluteString) -> \(upgradedURL.absoluteString)")
                }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }

            let (data, response) = try await session.data(from: url)
            report("decoded")
            let html: String
            if let decoded = String(data: data, encoding: .utf8) {
                html = decoded
            } else {
                html = String(decoding: data, as: UTF8.self)
            }
            return ReaderFetchedDocument(html: html, responseURL: response.url)
        }
    }
}
