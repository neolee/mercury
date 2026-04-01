//
//  FeedLoadUseCase.swift
//  Mercury
//

import FeedKit
import Foundation
import XMLKit

struct FeedLoadUseCase {
    struct VerifiedFeed {
        let feedURL: String
        let parsedFeed: FeedKit.Feed
        let title: String?
    }

    let jobRunner: JobRunner

    func loadAndVerifyFeed(from urlString: String) async throws -> VerifiedFeed {
        let normalizedURL = try FeedInputValidator.validateFeedURL(urlString)
        guard let url = URL(string: normalizedURL) else {
            throw FeedEditError.invalidURL
        }

        let parsedFeed = try await loadFeed(from: url)
        return VerifiedFeed(
            feedURL: normalizedURL,
            parsedFeed: parsedFeed,
            title: feedTitle(from: parsedFeed)
        )
    }

    func fetchFeedTitle(from urlString: String) async throws -> String? {
        try await loadAndVerifyFeed(from: urlString).title
    }

    private func loadFeed(from url: URL) async throws -> FeedKit.Feed {
        let networkTimeout = TaskTimeoutPolicy.networkTimeout(for: .syncFeeds)
        return try await jobRunner.run(label: "feedFetch", timeout: networkTimeout.resourceTimeout) { report in
            report("begin")
            let feed = try await FeedKit.Feed(url: url)
            report("ok")
            return feed
        }
    }

    private func feedTitle(from parsedFeed: FeedKit.Feed) -> String? {
        switch parsedFeed {
        case .rss(let rss):
            return rss.channel?.title
        case .atom(let atom):
            return atom.title?.text
        case .json(let json):
            return json.title
        }
    }
}
