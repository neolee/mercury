import XCTest
@testable import Mercury

final class WebViewLoadPolicyTests: XCTestCase {
    func test_shouldLoadRequestedURL_returnsTrueWhenNoPreviousRequestExists() {
        XCTAssertTrue(
            WebView.shouldLoadRequestedURL(
                lastNavigationID: nil,
                requestedNavigationID: 1,
                lastInitiatedRequest: nil,
                requestedRequest: WebRequest(
                    url: URL(string: "https://example.com/posts/article")!,
                    source: .entryFallback
                )
            )
        )
    }

    func test_shouldLoadRequestedURL_returnsFalseForSameRequestedURL() {
        let requestedURL = URL(string: "https://example.com/posts/article")!

        XCTAssertFalse(
            WebView.shouldLoadRequestedURL(
                lastNavigationID: 1,
                requestedNavigationID: 1,
                lastInitiatedRequest: WebRequest(url: requestedURL, source: .entryFallback),
                requestedRequest: WebRequest(url: requestedURL, source: .entryFallback)
            )
        )
    }

    func test_shouldLoadRequestedURL_ignoresTrailingSlashCanonicalization() {
        XCTAssertFalse(
            WebView.shouldLoadRequestedURL(
                lastNavigationID: 1,
                requestedNavigationID: 1,
                lastInitiatedRequest: WebRequest(
                    url: URL(string: "https://example.com/posts/article")!,
                    source: .entryFallback
                ),
                requestedRequest: WebRequest(
                    url: URL(string: "https://example.com/posts/article/")!,
                    source: .entryFallback
                )
            )
        )
    }

    func test_shouldLoadRequestedURL_returnsTrueWhenRequestedURLChangesFromHTTPToHTTPS() {
        XCTAssertTrue(
            WebView.shouldLoadRequestedURL(
                lastNavigationID: 1,
                requestedNavigationID: 1,
                lastInitiatedRequest: WebRequest(
                    url: URL(string: "http://example.com/posts/article")!,
                    source: .entryFallback
                ),
                requestedRequest: WebRequest(
                    url: URL(string: "https://example.com/posts/article")!,
                    source: .entryFallback
                )
            )
        )
    }

    func test_shouldLoadRequestedURL_returnsTrueForDifferentArticleURL() {
        XCTAssertTrue(
            WebView.shouldLoadRequestedURL(
                lastNavigationID: 1,
                requestedNavigationID: 1,
                lastInitiatedRequest: WebRequest(
                    url: URL(string: "https://example.com/posts/article-a")!,
                    source: .entryFallback
                ),
                requestedRequest: WebRequest(
                    url: URL(string: "https://example.com/posts/article-b")!,
                    source: .entryFallback
                )
            )
        )
    }

    func test_shouldLoadRequestedURL_returnsTrueWhenEntryNavigationIDChanges() {
        XCTAssertTrue(
            WebView.shouldLoadRequestedURL(
                lastNavigationID: 1,
                requestedNavigationID: 2,
                lastInitiatedRequest: WebRequest(
                    url: URL(string: "https://example.com/posts/article")!,
                    source: .entryFallback
                ),
                requestedRequest: WebRequest(
                    url: URL(string: "https://example.com/posts/article/")!,
                    source: .entryFallback
                )
            )
        )
    }

    func test_shouldLoadRequestedURL_returnsTrueWhenCanonicalRequestUpgradesSource() {
        XCTAssertTrue(
            WebView.shouldLoadRequestedURL(
                lastNavigationID: 1,
                requestedNavigationID: 1,
                lastInitiatedRequest: WebRequest(
                    url: URL(string: "https://example.com/posts/article")!,
                    source: .entryFallback
                ),
                requestedRequest: WebRequest(
                    url: URL(string: "https://example.com/posts/article/")!,
                    source: .documentBase
                )
            )
        )
    }
}
