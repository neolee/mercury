//
//  FeedTitleResolver.swift
//  Mercury
//

import Foundation
import SwiftSoup

enum FeedTitleResolver {
    static func resolveAutomaticFeedTitle(
        explicitTitle: String?,
        feedURL: String,
        siteURL: String?,
        fetchFeedTitle: (String) async throws -> String?
    ) async -> String? {
        if let explicit = normalize(explicitTitle) {
            return explicit
        }

        if let siteURL, let siteName = await fetchSiteName(from: siteURL) {
            return normalize(siteName)
        }

        if let feedName = try? await fetchFeedTitle(feedURL) {
            return normalize(feedName)
        }

        return nil
    }

    static func resolveAutomaticTitles(
        for feeds: [OPMLFeed],
        forceSiteNameAsFeedTitle: Bool,
        fetchFeedTitle: (String) async throws -> String?
    ) async -> [OPMLFeed] {
        var resolved: [OPMLFeed] = []
        resolved.reserveCapacity(feeds.count)

        for item in feeds {
            if forceSiteNameAsFeedTitle {
                let fetchedSiteName: String?
                if let siteURL = item.siteURL {
                    fetchedSiteName = await fetchSiteName(from: siteURL)
                } else {
                    fetchedSiteName = nil
                }
                let finalTitle = normalize(fetchedSiteName) ?? normalize(item.title)
                resolved.append(
                    OPMLFeed(
                        title: finalTitle,
                        feedURL: item.feedURL,
                        siteURL: item.siteURL
                    )
                )
                continue
            }

            if normalize(item.title) != nil {
                resolved.append(item)
                continue
            }

            let autoTitle = await resolveAutomaticFeedTitle(
                explicitTitle: item.title,
                feedURL: item.feedURL,
                siteURL: item.siteURL,
                fetchFeedTitle: fetchFeedTitle
            )

            resolved.append(
                OPMLFeed(
                    title: autoTitle,
                    feedURL: item.feedURL,
                    siteURL: item.siteURL
                )
            )
        }

        return resolved
    }

    private static func fetchSiteName(from urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }

        let candidateURLs: [URL]
        if url.scheme?.lowercased() == "http" {
            var secureComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
            secureComponents?.scheme = "https"
            if let secureURL = secureComponents?.url {
                candidateURLs = [secureURL, url]
            } else {
                candidateURLs = [url]
            }
        } else {
            candidateURLs = [url]
        }

        for candidateURL in candidateURLs {
            do {
                var request = URLRequest(url: candidateURL)
                request.timeoutInterval = TaskTimeoutPolicy.networkTimeout(for: .importOPML).requestTimeout
                let (data, _) = try await URLSession.shared.data(for: request)
                let html = String(decoding: data, as: UTF8.self)
                let document = try SwiftSoup.parse(html)

                if let ogName = try firstMetaContent(document: document, query: "meta[property=og:site_name]"),
                   ogName.isEmpty == false {
                    return ogName
                }

                if let appName = try firstMetaContent(document: document, query: "meta[name=application-name]"),
                   appName.isEmpty == false {
                    return appName
                }

                let title = try document.title().trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty == false {
                    return title
                }
            } catch {
                continue
            }
        }

        return nil
    }

    private static func firstMetaContent(document: Document, query: String) throws -> String? {
        guard let element = try document.select(query).first() else { return nil }
        let content = try element.attr("content").trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
