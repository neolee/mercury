//
//  FeedEntryMapper.swift
//  Mercury
//

import FeedKit
import Foundation
import XMLKit

struct FeedEntryMapper: Sendable {
    nonisolated init() {}

    func makeEntries(from parsedFeed: FeedKit.Feed, feedId: Int64, baseURLString: String?) -> [Entry] {
        switch parsedFeed {
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
                url: FeedEntryURLResolver.normalizeEntryURL(item.link, baseURLString: baseURLString),
                title: item.title,
                author: item.author,
                published: item.pubDate,
                summary: item.description
            )
        }
    }

    private func mapAtomEntries(_ entries: [AtomFeedEntry]?, feedId: Int64, baseURLString: String?) -> [Entry] {
        guard let entries else { return [] }
        return entries.compactMap { feedEntry in
            let selection = FeedEntryURLResolver.atomURLSelection(
                links: feedEntry.links,
                baseURLString: baseURLString
            )
            return makeEntry(
                feedId: feedId,
                guid: feedEntry.id,
                url: selection.preferredURL,
                title: feedEntry.title,
                author: feedEntry.authors?.first?.name,
                published: feedEntry.published ?? feedEntry.updated,
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
                url: FeedEntryURLResolver.normalizeEntryURL(item.url, baseURLString: baseURLString),
                title: item.title,
                author: item.author?.name,
                published: item.datePublished,
                summary: item.summary
            )
        }
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

        let preferredURLString = url.flatMap(URLHTTPSUpgrade.preferredHTTPSURLString(from:)) ?? url

        return Entry(
            id: nil,
            feedId: feedId,
            guid: guid,
            url: preferredURLString,
            title: title,
            author: author,
            publishedAt: published,
            summary: summary,
            isRead: false,
            createdAt: Date()
        )
    }
}
