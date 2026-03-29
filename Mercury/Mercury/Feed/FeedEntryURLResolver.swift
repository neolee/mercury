//
//  FeedEntryURLResolver.swift
//  Mercury
//

import Foundation
import FeedKit
import XMLKit

enum FeedEntryURLResolver {
    struct AtomURLSelection: Equatable {
        let legacyURL: String?
        let preferredURL: String?
    }

    static func normalizeEntryURL(_ urlString: String?, baseURLString: String?) -> String? {
        guard let urlString, urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }

        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("//") {
            return "https:\(trimmed)"
        }

        if let url = URL(string: trimmed), url.scheme != nil {
            return URLHTTPSUpgrade.preferredHTTPSURL(from: url).absoluteString
        }

        if let baseURLString, let baseURL = URL(string: baseURLString) {
            if let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
                return URLHTTPSUpgrade.preferredHTTPSURL(from: resolved).absoluteString
            }
        }

        if trimmed.contains(".") {
            return "https://\(trimmed)"
        }

        return trimmed
    }

    static func atomURLSelection(
        links: [AtomFeedLink]?,
        baseURLString: String?
    ) -> AtomURLSelection {
        let linkRecords = (links ?? []).compactMap { link -> (url: String, rel: String, type: String?)? in
            guard let href = normalizeEntryURL(link.attributes?.href, baseURLString: baseURLString) else {
                return nil
            }
            let rel = normalizedAtomLinkRelation(link.attributes?.rel)
            let type = normalizedAtomLinkType(link.attributes?.type)
            return (url: href, rel: rel, type: type)
        }

        let legacyURL = linkRecords.first?.url
        let preferredURL =
            linkRecords.first(where: { isPreferredAtomAlternateLink(rel: $0.rel, type: $0.type) })?.url ??
            linkRecords.first(where: { isPreferredAtomAlternateLinkWithoutType(rel: $0.rel, type: $0.type) })?.url ??
            linkRecords.first(where: { $0.type == "text/html" })?.url ??
            legacyURL

        return AtomURLSelection(
            legacyURL: legacyURL,
            preferredURL: preferredURL
        )
    }

    private static func normalizedAtomLinkRelation(_ relation: String?) -> String {
        let trimmed = relation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (trimmed?.isEmpty == false) ? trimmed! : "alternate"
    }

    private static func normalizedAtomLinkType(_ type: String?) -> String? {
        let trimmed = type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func isPreferredAtomAlternateLink(rel: String, type: String?) -> Bool {
        guard rel == "alternate", let type else {
            return false
        }
        return type == "text/html" || type == "application/xhtml+xml"
    }

    private static func isPreferredAtomAlternateLinkWithoutType(rel: String, type: String?) -> Bool {
        rel == "alternate" && type == nil
    }
}
