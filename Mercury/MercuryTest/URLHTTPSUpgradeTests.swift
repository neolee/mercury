import Foundation
import Testing
@testable import Mercury

@Suite("URL HTTPS Upgrade")
struct URLHTTPSUpgradeTests {
    @Test("Upgrades http URL to https while preserving path query and fragment")
    func upgradesHTTPURL() {
        let url = URL(string: "http://example.com/articles/post?id=42#section")!

        let preferredURL = URLHTTPSUpgrade.preferredHTTPSURL(from: url)

        #expect(preferredURL.absoluteString == "https://example.com/articles/post?id=42#section")
    }

    @Test("Drops explicit port 80 when upgrading to https")
    func dropsPort80() {
        let url = URL(string: "http://example.com:80/articles/post")!

        let preferredURL = URLHTTPSUpgrade.preferredHTTPSURL(from: url)

        #expect(preferredURL.absoluteString == "https://example.com/articles/post")
    }

    @Test("Leaves https URL unchanged")
    func keepsHTTPSURL() {
        let url = URL(string: "https://example.com/articles/post")!

        let preferredURL = URLHTTPSUpgrade.preferredHTTPSURL(from: url)

        #expect(preferredURL == url)
    }

    @Test("String helper returns upgraded absolute string")
    func upgradesStringInput() {
        let preferredURLString = URLHTTPSUpgrade.preferredHTTPSURLString(
            from: "http://example.com/articles/post"
        )

        #expect(preferredURLString == "https://example.com/articles/post")
    }

    @Test("String helper returns nil for malformed input")
    func rejectsMalformedString() {
        let preferredURLString = URLHTTPSUpgrade.preferredHTTPSURLString(from: "://bad")

        #expect(preferredURLString == nil)
    }
}
