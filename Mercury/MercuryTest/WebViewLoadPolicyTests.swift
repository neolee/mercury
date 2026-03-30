import XCTest
@testable import Mercury

final class WebViewLoadPolicyTests: XCTestCase {
    func test_shouldLoadRequestedURL_returnsTrueWhenNoPreviousRequestExists() {
        XCTAssertTrue(
            WebView.shouldLoadRequestedURL(
                lastRequestedURL: nil,
                requestedURL: URL(string: "https://example.com/posts/article")!
            )
        )
    }

    func test_shouldLoadRequestedURL_returnsFalseForSameRequestedURL() {
        let requestedURL = URL(string: "https://example.com/posts/article")!

        XCTAssertFalse(
            WebView.shouldLoadRequestedURL(
                lastRequestedURL: requestedURL,
                requestedURL: requestedURL
            )
        )
    }

    func test_shouldLoadRequestedURL_ignoresDifferentRedirectedFinalURL() {
        XCTAssertFalse(
            WebView.shouldLoadRequestedURL(
                lastRequestedURL: URL(string: "https://example.com/posts/article")!,
                requestedURL: URL(string: "https://example.com/posts/article")!
            )
        )
    }
}
