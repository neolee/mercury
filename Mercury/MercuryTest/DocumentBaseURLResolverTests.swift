import Foundation
import Testing
@testable import Mercury

@Suite("Document Base URL Resolver")
@MainActor
struct DocumentBaseURLResolverTests {
    @Test("Resolve prefers absolute base href")
    func resolvePrefersAbsoluteBaseHref() {
        let html = """
        <html>
          <head><base href="https://example.com/posts/article/"></head>
          <body><img src="media/header.png"></body>
        </html>
        """

        let resolved = DocumentBaseURLResolver.resolve(
            html: html,
            responseURL: URL(string: "https://example.com/posts/article/"),
            fallbackURL: URL(string: "https://example.com/posts/article")
        )

        #expect(resolved?.url.absoluteString == "https://example.com/posts/article/")
        #expect(resolved?.source == .htmlBaseElement)
        #expect(resolved?.isPersistable == true)
    }

    @Test("Resolve uses response URL when no base href exists")
    func resolveUsesResponseURLWhenNoBaseHrefExists() {
        let resolved = DocumentBaseURLResolver.resolve(
            html: "<html><body>Hello</body></html>",
            responseURL: URL(string: "https://example.com/posts/article/"),
            fallbackURL: URL(string: "https://example.com/posts/article")
        )

        #expect(resolved?.url.absoluteString == "https://example.com/posts/article/")
        #expect(resolved?.source == .responseURL)
        #expect(resolved?.isPersistable == true)
    }

    @Test("Resolve marks entry URL fallback as non-persistable")
    func resolveMarksEntryURLFallbackAsNonPersistable() {
        let resolved = DocumentBaseURLResolver.resolve(
            html: "<html><body>Hello</body></html>",
            responseURL: nil,
            fallbackURL: URL(string: "https://example.com/posts/article")
        )

        #expect(resolved?.url.absoluteString == "https://example.com/posts/article")
        #expect(resolved?.source == .entryURLFallback)
        #expect(resolved?.isPersistable == false)
    }

    @Test("Trusted persisted base URL requires absolute base href")
    func trustedPersistedBaseURLRequiresAbsoluteBaseHref() {
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

        #expect(DocumentBaseURLResolver.trustedPersistedBaseURL(from: relativeHTML) == nil)
        #expect(
            DocumentBaseURLResolver.trustedPersistedBaseURL(from: absoluteHTML)?.absoluteString ==
                "https://example.com/posts/article/"
        )
    }
}
