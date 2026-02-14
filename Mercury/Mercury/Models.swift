//
//  Models.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Foundation
import GRDB

struct Feed: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "feed"

    var id: Int64?
    var title: String?
    var feedURL: String
    var siteURL: String?
    var unreadCount: Int
    var lastFetchedAt: Date?
    var createdAt: Date

    mutating func didInsert(with rowID: Int64, for column: String?) {
        id = rowID
    }
}

struct Entry: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "entry"

    var id: Int64?
    var feedId: Int64
    var guid: String?
    var url: String?
    var title: String?
    var author: String?
    var publishedAt: Date?
    var summary: String?
    var isRead: Bool
    var createdAt: Date

    mutating func didInsert(with rowID: Int64, for column: String?) {
        id = rowID
    }
}

struct EntryListItem: Identifiable, Hashable {
    var id: Int64
    var feedId: Int64
    var title: String?
    var publishedAt: Date?
    var createdAt: Date
    var isRead: Bool
    var feedSourceTitle: String?
}

enum ContentDisplayMode: String, Codable {
    case web
    case cleaned
}

struct Content: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "content"

    var id: Int64?
    var entryId: Int64
    var html: String?
    var markdown: String?
    var displayMode: String
    var createdAt: Date

    mutating func didInsert(with rowID: Int64, for column: String?) {
        id = rowID
    }
}

struct ContentHTMLCache: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "content_html_cache"

    var entryId: Int64
    var themeId: String
    var html: String
    var updatedAt: Date
}
