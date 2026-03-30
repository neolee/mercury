import XCTest
@testable import Mercury

final class ReaderDocumentBaseURLResolverTests: XCTestCase {
    func test_resolve_prefersAbsoluteBaseHref() {
        let html = """
        <html>
          <head><base href="https://example.com/posts/article/"></head>
          <body><img src="media/header.png"></body>
        </html>
        """

        let resolved = ReaderDocumentBaseURLResolver.resolve(
            html: html,
            responseURL: URL(string: "https://example.com/posts/article/"),
            fallbackURL: URL(string: "https://example.com/posts/article")
        )

        XCTAssertEqual(resolved?.url.absoluteString, "https://example.com/posts/article/")
        XCTAssertEqual(resolved?.source, .htmlBaseElement)
        XCTAssertEqual(resolved?.isPersistable, true)
    }

    func test_resolve_usesResponseURLWhenNoBaseHrefExists() {
        let resolved = ReaderDocumentBaseURLResolver.resolve(
            html: "<html><body>Hello</body></html>",
            responseURL: URL(string: "https://example.com/posts/article/"),
            fallbackURL: URL(string: "https://example.com/posts/article")
        )

        XCTAssertEqual(resolved?.url.absoluteString, "https://example.com/posts/article/")
        XCTAssertEqual(resolved?.source, .responseURL)
        XCTAssertEqual(resolved?.isPersistable, true)
    }

    func test_resolve_marksEntryURLFallbackAsNonPersistable() {
        let resolved = ReaderDocumentBaseURLResolver.resolve(
            html: "<html><body>Hello</body></html>",
            responseURL: nil,
            fallbackURL: URL(string: "https://example.com/posts/article")
        )

        XCTAssertEqual(resolved?.url.absoluteString, "https://example.com/posts/article")
        XCTAssertEqual(resolved?.source, .entryURLFallback)
        XCTAssertEqual(resolved?.isPersistable, false)
    }

    func test_trustedPersistedBaseURL_requiresAbsoluteBaseHref() {
        let relativeHTML = """
        <html>
          <head><base href="/posts/article/"></head>
          <body>Hello</body>
        </html>
        """
        let absoluteHTML = """
        <html>
          <head><base href="https://example.com/posts/article/"></head>
          <body>Hello</body>
        </html>
        """

        XCTAssertNil(ReaderDocumentBaseURLResolver.trustedPersistedBaseURL(from: relativeHTML))
        XCTAssertEqual(
            ReaderDocumentBaseURLResolver.trustedPersistedBaseURL(from: absoluteHTML)?.absoluteString,
            "https://example.com/posts/article/"
        )
    }
}
