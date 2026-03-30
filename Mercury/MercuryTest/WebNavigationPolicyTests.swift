import XCTest
@testable import Mercury

final class WebNavigationPolicyTests: XCTestCase {
    func test_fallbackRequest_upgradesHTTPArticleURLToHTTPS() {
        let entryURL = URL(string: "http://example.com/posts/article")!

        let resolvedRequest = WebNavigationPolicy.fallbackRequest(entryURL: entryURL)

        XCTAssertEqual(resolvedRequest.url, URL(string: "https://example.com/posts/article")!)
        XCTAssertEqual(resolvedRequest.source, .entryFallback)
    }

    func test_preferredRequest_usesDocumentBaseURLForTrailingSlashCanonicalization() {
        let entryURL = URL(string: "https://example.com/posts/article")!
        let documentBaseURL = URL(string: "https://example.com/posts/article/")!

        let resolvedRequest = WebNavigationPolicy.preferredRequest(
            entryURL: entryURL,
            documentBaseURL: documentBaseURL
        )

        XCTAssertEqual(resolvedRequest.url, documentBaseURL)
        XCTAssertEqual(resolvedRequest.source, .documentBase)
    }

    func test_preferredRequest_ignoresUnrelatedAbsoluteBaseURL() {
        let entryURL = URL(string: "https://example.com/posts/article")!
        let documentBaseURL = URL(string: "https://cdn.example.com/assets/")!

        let resolvedRequest = WebNavigationPolicy.preferredRequest(
            entryURL: entryURL,
            documentBaseURL: documentBaseURL
        )

        XCTAssertEqual(resolvedRequest.url, entryURL)
        XCTAssertEqual(resolvedRequest.source, .entryFallback)
    }

    func test_equivalentTopLevelNavigationURLs_treatsTrailingSlashAsSamePage() {
        XCTAssertTrue(
            WebNavigationPolicy.areEquivalentTopLevelNavigationURLs(
                URL(string: "https://example.com/posts/article")!,
                URL(string: "https://example.com/posts/article/")!
            )
        )
    }

    func test_equivalentTopLevelNavigationURLs_doesNotTreatHTTPAndHTTPSAsSameIssuedRequest() {
        XCTAssertFalse(
            WebNavigationPolicy.areEquivalentTopLevelNavigationURLs(
                URL(string: "http://example.com/posts/article")!,
                URL(string: "https://example.com/posts/article")!
            )
        )
    }

    func test_shouldReloadTopLevelRequest_whenCanonicalRequestUpgradesSource() {
        let lastRequest = WebRequest(
            url: URL(string: "https://example.com/posts/article")!,
            source: .entryFallback
        )
        let requestedRequest = WebRequest(
            url: URL(string: "https://example.com/posts/article/")!,
            source: .documentBase
        )

        XCTAssertTrue(
            WebNavigationPolicy.shouldReloadTopLevelRequest(
                lastRequest: lastRequest,
                requestedRequest: requestedRequest
            )
        )
    }
}
