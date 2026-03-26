import Foundation
import Testing
@testable import Mercury

@Suite("Reader Fetch Redirect Policy")
struct ReaderFetchRedirectPolicyTests {
    @Test("Upgrades same-host insecure redirect back to https")
    func upgradesSameHostInsecureRedirect() {
        let originalURL = URL(string: "https://mariozechner.at/posts/2026-03-25-thoughts-on-slowing-the-fuck-down")!
        let redirectURL = URL(string: "http://mariozechner.at/posts/2026-03-25-thoughts-on-slowing-the-fuck-down/?ref=feed")!

        let upgradedURL = ReaderFetchRedirectPolicy.upgradedRedirectURL(
            originalURL: originalURL,
            redirectURL: redirectURL
        )

        #expect(upgradedURL?.absoluteString == "https://mariozechner.at/posts/2026-03-25-thoughts-on-slowing-the-fuck-down/?ref=feed")
    }

    @Test("Keeps non-http redirects unchanged")
    func doesNotUpgradeSecureRedirect() {
        let originalURL = URL(string: "https://example.com/post")!
        let redirectURL = URL(string: "https://example.com/post/")!

        let upgradedURL = ReaderFetchRedirectPolicy.upgradedRedirectURL(
            originalURL: originalURL,
            redirectURL: redirectURL
        )

        #expect(upgradedURL == nil)
    }

    @Test("Does not rewrite cross-host insecure redirects")
    func doesNotUpgradeCrossHostRedirect() {
        let originalURL = URL(string: "https://example.com/post")!
        let redirectURL = URL(string: "http://cdn.example.com/post/")!

        let upgradedURL = ReaderFetchRedirectPolicy.upgradedRedirectURL(
            originalURL: originalURL,
            redirectURL: redirectURL
        )

        #expect(upgradedURL == nil)
    }

    @Test("Does not rewrite redirects from non-https origins")
    func doesNotUpgradeWhenOriginalRequestWasNotSecure() {
        let originalURL = URL(string: "http://example.com/post")!
        let redirectURL = URL(string: "http://example.com/post/")!

        let upgradedURL = ReaderFetchRedirectPolicy.upgradedRedirectURL(
            originalURL: originalURL,
            redirectURL: redirectURL
        )

        #expect(upgradedURL == nil)
    }

    @Test("Drops explicit port 80 when upgrading to https")
    func dropsPort80WhenUpgrading() {
        let originalURL = URL(string: "https://example.com/post")!
        let redirectURL = URL(string: "http://example.com:80/post/")!

        let upgradedURL = ReaderFetchRedirectPolicy.upgradedRedirectURL(
            originalURL: originalURL,
            redirectURL: redirectURL
        )

        #expect(upgradedURL?.absoluteString == "https://example.com/post/")
    }
}
