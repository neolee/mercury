import Foundation
import SwiftSoup

enum ReaderDocumentBaseURLResolver {
    static func resolve(
        html: String,
        responseURL: URL?,
        fallbackURL: URL?
    ) -> ReaderResolvedDocumentBaseURL? {
        if let baseHref = firstBaseHref(in: html),
           let baseURL = resolveBaseHref(baseHref, referenceURL: responseURL ?? fallbackURL) {
            return ReaderResolvedDocumentBaseURL(
                url: baseURL,
                source: .htmlBaseElement,
                isPersistable: responseURL != nil || isAbsoluteBaseHref(baseHref)
            )
        }

        if let responseURL {
            return ReaderResolvedDocumentBaseURL(
                url: responseURL,
                source: .responseURL,
                isPersistable: true
            )
        }

        if let fallbackURL {
            return ReaderResolvedDocumentBaseURL(
                url: fallbackURL,
                source: .entryURLFallback,
                isPersistable: false
            )
        }

        return nil
    }

    static func trustedPersistedBaseURL(from html: String) -> URL? {
        guard let baseHref = firstBaseHref(in: html),
              isAbsoluteBaseHref(baseHref) else {
            return nil
        }
        return resolveBaseHref(baseHref, referenceURL: nil)
    }

    private static func firstBaseHref(in html: String) -> String? {
        guard let document = try? SwiftSoup.parse(html),
              let element = try? document.select("base[href]").first(),
              let href = try? element.attr("href").trimmingCharacters(in: .whitespacesAndNewlines),
              href.isEmpty == false else {
            return nil
        }
        return href
    }

    private static func resolveBaseHref(_ href: String, referenceURL: URL?) -> URL? {
        if let absoluteURL = URL(string: href), absoluteURL.scheme != nil {
            return absoluteURL
        }
        guard let referenceURL else {
            return nil
        }
        return URL(string: href, relativeTo: referenceURL)?.absoluteURL
    }

    private static func isAbsoluteBaseHref(_ href: String) -> Bool {
        guard let url = URL(string: href) else {
            return false
        }
        return url.scheme != nil
    }
}
