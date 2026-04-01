import Foundation
import Testing
@testable import Mercury

@Suite("Web Navigation Policy")
struct WebNavigationPolicyTests {
    @Test("Fallback request upgrades HTTP article URL to HTTPS")
    func fallbackRequestUpgradesHTTPArticleURLToHTTPS() {
        let entryURL = URL(string: "http://example.com/posts/article")!

        let resolvedRequest = WebNavigationPolicy.fallbackRequest(entryURL: entryURL)

        #expect(resolvedRequest.url == URL(string: "https://example.com/posts/article")!)
        #expect(resolvedRequest.source == .entryFallback)
    }

    @Test("Preferred request uses document base URL for trailing slash canonicalization")
    func preferredRequestUsesDocumentBaseURLForTrailingSlashCanonicalization() {
        let entryURL = URL(string: "https://example.com/posts/article")!
        let documentBaseURL = URL(string: "https://example.com/posts/article/")!

        let resolvedRequest = WebNavigationPolicy.preferredRequest(
            entryURL: entryURL,
            documentBaseURL: documentBaseURL
        )

        #expect(resolvedRequest.url == documentBaseURL)
        #expect(resolvedRequest.source == .documentBase)
    }

    @Test("Preferred request ignores unrelated absolute base URL")
    func preferredRequestIgnoresUnrelatedAbsoluteBaseURL() {
        let entryURL = URL(string: "https://example.com/posts/article")!
        let documentBaseURL = URL(string: "https://cdn.example.com/assets/")!

        let resolvedRequest = WebNavigationPolicy.preferredRequest(
            entryURL: entryURL,
            documentBaseURL: documentBaseURL
        )

        #expect(resolvedRequest.url == entryURL)
        #expect(resolvedRequest.source == .entryFallback)
    }

    @Test("Equivalent top-level navigation URLs treat trailing slash as same page")
    func equivalentTopLevelNavigationURLsTreatsTrailingSlashAsSamePage() {
        #expect(
            WebNavigationPolicy.areEquivalentTopLevelNavigationURLs(
                URL(string: "https://example.com/posts/article")!,
                URL(string: "https://example.com/posts/article/")!
            )
        )
    }

    @Test("Equivalent top-level navigation URLs do not treat HTTP and HTTPS as same issued request")
    func equivalentTopLevelNavigationURLsDoesNotTreatHTTPAndHTTPSAsSameIssuedRequest() {
        #expect(!WebNavigationPolicy.areEquivalentTopLevelNavigationURLs(
            URL(string: "http://example.com/posts/article")!,
            URL(string: "https://example.com/posts/article")!
        ))
    }

    @Test("Should reload top-level request when canonical request upgrades source")
    func shouldReloadTopLevelRequestWhenCanonicalRequestUpgradesSource() {
        let lastRequest = WebRequest(
            url: URL(string: "https://example.com/posts/article")!,
            source: .entryFallback
        )
        let requestedRequest = WebRequest(
            url: URL(string: "https://example.com/posts/article/")!,
            source: .documentBase
        )

        #expect(
            WebNavigationPolicy.shouldReloadTopLevelRequest(
                lastRequest: lastRequest,
                requestedRequest: requestedRequest
            )
        )
    }
}
