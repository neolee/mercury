//
//  SyncService.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Foundation
import FeedKit
import GRDB
import XMLKit

struct FeedSyncDiagnosticError: LocalizedError {
    let underlying: Error
    let diagnostics: [String]

    var errorDescription: String? {
        underlying.localizedDescription
    }
}

final class RedirectCaptureDelegate: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var redirects: [String] = []

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url?.absoluteString {
            lock.lock()
            redirects.append(url)
            lock.unlock()
        }
        completionHandler(request)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return redirects
    }
}

final class SyncService {
    private let db: DatabaseManager
    private let jobRunner: JobRunner

    init(db: DatabaseManager, jobRunner: JobRunner) {
        self.db = db
        self.jobRunner = jobRunner
    }

    func syncFeed(withId feedId: Int64) async throws {
        guard let feed = try await db.read({ db in
            try Feed.filter(Column("id") == feedId).fetchOne(db)
        }) else { return }

        try await sync(feed)
        try await recalculateUnreadCount(for: feedId)
    }

    func fetchFeedTitle(from urlString: String) async throws -> String? {
        guard let url = URL(string: urlString) else { return nil }

        let parsedFeed = try await loadFeed(from: url)
        switch parsedFeed {
        case .rss(let rss):
            return rss.channel?.title
        case .atom(let atom):
            return atom.title?.text
        case .json(let json):
            return json.title
        }
    }

    private func sync(_ feed: Feed) async throws {
        guard let feedId = feed.id else { return }
        guard let url = URL(string: feed.feedURL) else { return }

        let parsedFeed: FeedKit.Feed
        do {
            parsedFeed = try await loadFeed(from: url)
        } catch {
            throw await enrichSyncError(
                error,
                requestedURL: url,
                declaredFeedURL: feed.feedURL
            )
        }
        let entries = mapEntries(feed: parsedFeed, feedId: feedId, baseURLString: feed.siteURL ?? feed.feedURL)

        try await db.write { db in
            for var entry in entries {
                try entry.insert(db, onConflict: .ignore)
            }

            var updated = feed
            updated.lastFetchedAt = Date()
            try updated.update(db)
        }
    }

    private func mapEntries(feed: FeedKit.Feed, feedId: Int64, baseURLString: String?) -> [Entry] {
        switch feed {
        case .rss(let rss):
            return mapRSSItems(rss.channel?.items, feedId: feedId, baseURLString: baseURLString)
        case .atom(let atom):
            return mapAtomEntries(atom.entries, feedId: feedId, baseURLString: baseURLString)
        case .json(let json):
            return mapJSONItems(json.items, feedId: feedId, baseURLString: baseURLString)
        }
    }

    private func mapRSSItems(_ items: [RSSFeedItem]?, feedId: Int64, baseURLString: String?) -> [Entry] {
        guard let items else { return [] }
        return items.compactMap { item in
            makeEntry(
                feedId: feedId,
                guid: item.link,
                url: normalizeEntryURL(item.link, baseURLString: baseURLString),
                title: item.title,
                author: item.author,
                published: item.pubDate,
                summary: item.description
            )
        }
    }

    private func mapAtomEntries(_ entries: [AtomFeedEntry]?, feedId: Int64, baseURLString: String?) -> [Entry] {
        guard let entries else { return [] }
        return entries.compactMap { entry in
            let url = normalizeEntryURL(entry.links?.first?.attributes?.href, baseURLString: baseURLString)
            return makeEntry(
                feedId: feedId,
                guid: entry.id,
                url: url,
                title: entry.title,
                author: entry.authors?.first?.name,
                published: entry.published ?? entry.updated,
                summary: nil
            )
        }
    }

    private func mapJSONItems(_ items: [JSONFeedItem]?, feedId: Int64, baseURLString: String?) -> [Entry] {
        guard let items else { return [] }
        return items.compactMap { item in
            makeEntry(
                feedId: feedId,
                guid: item.id,
                url: normalizeEntryURL(item.url, baseURLString: baseURLString),
                title: item.title,
                author: item.author?.name,
                published: item.datePublished,
                summary: item.summary
            )
        }
    }

    private func loadFeed(from url: URL) async throws -> FeedKit.Feed {
        try await jobRunner.run(label: "feedFetch", timeout: 20) { report in
            report("begin")
            let feed = try await FeedKit.Feed(url: url)
            report("ok")
            return feed
        }
    }

    private func enrichSyncError(_ error: Error, requestedURL: URL, declaredFeedURL: String) async -> Error {
        var diagnostics: [String] = [
            "requestURL=\(requestedURL.absoluteString)",
            "requestScheme=\(requestedURL.scheme ?? "(missing)")",
            "requestHost=\(requestedURL.host ?? "(missing)")",
            "declaredFeedURL=\(declaredFeedURL)"
        ]

        let nsError = error as NSError
        diagnostics.append("syncErrorDomain=\(nsError.domain)")
        diagnostics.append("syncErrorCode=\(nsError.code)")

        if isATSError(error) {
            let probeLines = await probeRequestDiagnostics(for: requestedURL)
            diagnostics.append(contentsOf: probeLines)
        }

        return FeedSyncDiagnosticError(underlying: error, diagnostics: diagnostics)
    }

    private func isATSError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == -1022 {
            return true
        }
        let message = nsError.localizedDescription.lowercased()
        return message.contains("app transport security policy requires the use of a secure connection")
    }

    private func probeRequestDiagnostics(for url: URL) async -> [String] {
        var lines: [String] = [
            "probeRequestedURL=\(url.absoluteString)"
        ]

        let delegate = RedirectCaptureDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                lines.append("probeStatusCode=\(http.statusCode)")
                lines.append("probeResponseURL=\(http.url?.absoluteString ?? "(missing)")")
                lines.append("probeMimeType=\(http.mimeType ?? "(missing)")")
            } else {
                lines.append("probeResponseType=\(String(describing: type(of: response)))")
            }
        } catch {
            let probeError = error as NSError
            lines.append("probeErrorDomain=\(probeError.domain)")
            lines.append("probeErrorCode=\(probeError.code)")
            lines.append("probeErrorDescription=\(probeError.localizedDescription)")
            if let failingURL = probeError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
                lines.append("probeFailingURL=\(failingURL.absoluteString)")
            }
        }

        let redirects = delegate.snapshot()
        if redirects.isEmpty == false {
            lines.append("probeRedirectChain=\(redirects.joined(separator: " -> "))")
        }

        return lines
    }

    private func makeEntry(
        feedId: Int64,
        guid: String?,
        url: String?,
        title: String?,
        author: String?,
        published: Date?,
        summary: String?
    ) -> Entry? {
        guard guid != nil || url != nil else { return nil }

        let secureURLString: String?
        if let url, let converted = forceSecureURL(url) {
            secureURLString = converted
        } else {
            secureURLString = url
        }

        return Entry(
            id: nil,
            feedId: feedId,
            guid: guid,
            url: secureURLString,
            title: title,
            author: author,
            publishedAt: published,
            summary: summary,
            isRead: false,
            createdAt: Date()
        )
    }

    private func recalculateUnreadCount(for feedId: Int64) async throws {
        _ = try await UnreadCountUseCase(database: db)
            .recalculate(forFeedId: feedId)
    }

    private func forceSecureURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "http" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            return components?.url
        }
        return url
    }

    private func forceSecureURL(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        guard let secureURL = forceSecureURL(url) else { return nil }
        return secureURL.absoluteString
    }

    private func normalizeEntryURL(_ urlString: String?, baseURLString: String?) -> String? {
        guard let urlString, urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }

        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("//") {
            return "https:\(trimmed)"
        }

        if let url = URL(string: trimmed), url.scheme != nil {
            return forceSecureURL(url)?.absoluteString ?? url.absoluteString
        }

        if let baseURLString, let baseURL = URL(string: baseURLString) {
            if let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
                return forceSecureURL(resolved)?.absoluteString ?? resolved.absoluteString
            }
        }

        if trimmed.contains(".") {
            return "https://\(trimmed)"
        }

        return trimmed
    }

}

enum SyncError: Error {
    case missingOPML([String])
}

extension SyncError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingOPML(let paths):
            let list = paths.joined(separator: "\n")
            return "OPML not found. Tried:\n\(list)"
        }
    }
}
