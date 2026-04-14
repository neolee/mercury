import Foundation
import Testing
@testable import Mercury

@Suite("Web View Load Policy")
@MainActor
struct WebViewLoadPolicyTests {
    @Test("Should load requested URL when no previous request exists")
    func shouldLoadRequestedURLReturnsTrueWhenNoPreviousRequestExists() {
        #expect(
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

    @Test("Should not load requested URL for same requested URL")
    func shouldLoadRequestedURLReturnsFalseForSameRequestedURL() {
        let requestedURL = URL(string: "https://example.com/posts/article")!

        #expect(!WebView.shouldLoadRequestedURL(
            lastNavigationID: 1,
            requestedNavigationID: 1,
            lastInitiatedRequest: WebRequest(url: requestedURL, source: .entryFallback),
            requestedRequest: WebRequest(url: requestedURL, source: .entryFallback)
        ))
    }

    @Test("Should not load requested URL for trailing slash canonicalization")
    func shouldLoadRequestedURLIgnoresTrailingSlashCanonicalization() {
        #expect(!WebView.shouldLoadRequestedURL(
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
        ))
    }

    @Test("Should load requested URL when request changes from HTTP to HTTPS")
    func shouldLoadRequestedURLReturnsTrueWhenRequestedURLChangesFromHTTPToHTTPS() {
        #expect(
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

    @Test("Should load requested URL for different article URL")
    func shouldLoadRequestedURLReturnsTrueForDifferentArticleURL() {
        #expect(
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

    @Test("Should load requested URL when entry navigation ID changes")
    func shouldLoadRequestedURLReturnsTrueWhenEntryNavigationIDChanges() {
        #expect(
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

    @Test("Should load requested URL when canonical request upgrades source")
    func shouldLoadRequestedURLReturnsTrueWhenCanonicalRequestUpgradesSource() {
        #expect(
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
