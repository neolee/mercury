//
//  SyncService.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Foundation
import FeedKit
import GRDB

struct FeedSyncDiagnosticError: LocalizedError {
    let underlying: Error
    let diagnostics: [String]

    var errorDescription: String? {
        underlying.localizedDescription
    }
}

final class RedirectCaptureDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

final class SyncService: @unchecked Sendable {
    struct SyncedFeedContext {
        let feed: Feed
        let parsedFeed: FeedKit.Feed
    }

    private let db: DatabaseManager
    private let feedLoadUseCase: FeedLoadUseCase
    private let feedEntryMapper: FeedEntryMapper
    private let rateLimitStoreKey = "RateLimitedHostsUntil"
    private let rateLimitCooldownSeconds: TimeInterval = 4 * 60 * 60

    init(db: DatabaseManager, feedLoadUseCase: FeedLoadUseCase, feedEntryMapper: FeedEntryMapper) {
        self.db = db
        self.feedLoadUseCase = feedLoadUseCase
        self.feedEntryMapper = feedEntryMapper
    }

    func syncFeed(withId feedId: Int64) async throws {
        _ = try await syncFeedWithContext(withId: feedId)
    }

    func syncFeedWithContext(withId feedId: Int64) async throws -> SyncedFeedContext? {
        guard let feed = try await db.read({ db in
            try Feed.filter(Column("id") == feedId).fetchOne(db)
        }) else { return nil }

        return try await sync(feed)
    }

    private func sync(_ feed: Feed) async throws -> SyncedFeedContext? {
        guard feed.id != nil else { return nil }
        let normalizedFeedURL = try FeedInputValidator.validateFeedURL(feed.feedURL)
        guard let url = URL(string: normalizedFeedURL) else {
            throw FeedEditError.invalidURL
        }
        if let host = url.host?.lowercased(), isHostRateLimited(host) {
            return nil
        }

        let verifiedFeed: FeedLoadUseCase.VerifiedFeed
        do {
            verifiedFeed = try await feedLoadUseCase.loadAndVerifyFeed(from: normalizedFeedURL)
        } catch {
            if isHTTP429Error(error), let host = url.host?.lowercased() {
                setHostRateLimit(host, until: Date().addingTimeInterval(rateLimitCooldownSeconds))
            }
            throw await enrichSyncError(
                error,
                requestedURL: url,
                declaredFeedURL: feed.feedURL
            )
        }
        try await syncParsedFeed(verifiedFeed.parsedFeed, into: feed)

        if let host = url.host?.lowercased() {
            clearHostRateLimit(host)
        }

        return SyncedFeedContext(feed: feed, parsedFeed: verifiedFeed.parsedFeed)
    }

    func syncParsedFeed(_ parsedFeed: FeedKit.Feed, into feed: Feed) async throws {
        guard let feedId = feed.id else { return }
        let entries = feedEntryMapper.makeEntries(
            from: parsedFeed,
            feedId: feedId,
            baseURLString: feed.siteURL ?? feed.feedURL
        )
        try await db.write {
            for var entry in entries {
                try entry.insert($0, onConflict: .ignore)
            }
            var updated = feed
            updated.lastFetchedAt = Date()
            try updated.update($0)
        }
    }

    private func isHTTP429Error(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == 429 {
            return true
        }

        let message = nsError.localizedDescription.lowercased()
        if message.contains("status code: 429") || message.contains("status code 429") {
            return true
        }

        return false
    }

    private func isHostRateLimited(_ host: String) -> Bool {
        var limits = loadHostRateLimits()
        let now = Date()
        var changed = false

        for (key, timestamp) in limits where Date(timeIntervalSince1970: timestamp) <= now {
            limits.removeValue(forKey: key)
            changed = true
        }

        if changed {
            saveHostRateLimits(limits)
        }

        guard let untilTimestamp = limits[host] else {
            return false
        }

        return Date(timeIntervalSince1970: untilTimestamp) > now
    }

    private func setHostRateLimit(_ host: String, until: Date) {
        var limits = loadHostRateLimits()
        limits[host] = until.timeIntervalSince1970
        saveHostRateLimits(limits)
    }

    private func clearHostRateLimit(_ host: String) {
        var limits = loadHostRateLimits()
        if limits.removeValue(forKey: host) != nil {
            saveHostRateLimits(limits)
        }
    }

    private func loadHostRateLimits() -> [String: TimeInterval] {
        guard let stored = UserDefaults.standard.dictionary(forKey: rateLimitStoreKey) else {
            return [:]
        }
        var result: [String: TimeInterval] = [:]
        result.reserveCapacity(stored.count)
        for (key, value) in stored {
            if let number = value as? NSNumber {
                result[key] = number.doubleValue
            }
        }
        return result
    }

    private func saveHostRateLimits(_ values: [String: TimeInterval]) {
        UserDefaults.standard.set(values, forKey: rateLimitStoreKey)
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
        let networkTimeout = TaskTimeoutPolicy.networkTimeout(for: .syncFeeds)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = networkTimeout.requestTimeout
        configuration.timeoutIntervalForResource = networkTimeout.resourceTimeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = networkTimeout.requestTimeout

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

}
