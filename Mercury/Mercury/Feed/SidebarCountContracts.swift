//
//  SidebarCountContracts.swift
//  Mercury
//

import Foundation

// MARK: - Projection item types

struct SidebarTagItem: Identifiable, Sendable {
    var id: Int64 { tagId }
    var tagId: Int64
    var name: String
    var normalizedName: String
    var isProvisional: Bool
    /// Count of entries associated with this tag. Equivalent to `Tag.usageCount`.
    var usageCount: Int
    /// Count of unread entries associated with this tag.
    var unreadCount: Int
}

// MARK: - Projection root

/// A complete snapshot of all sidebar counter data, computed from the database by `SidebarCountStore`.
struct SidebarProjection: Sendable {
    /// Total number of unread entries across all feeds.
    var totalUnread: Int
    /// Total number of starred entries.
    var totalStarred: Int
    /// Number of starred entries that are also unread.
    var starredUnread: Int
    /// Per-feed unread counts keyed by feed ID. Feeds with zero unread entries are not present.
    var feedUnreadCounts: [Int64: Int]
    /// Visible tag rows after applying `SidebarTagVisibilityPolicy`. Ordered by `usageCount DESC, normalizedName ASC`.
    var tags: [SidebarTagItem]

    static let empty = SidebarProjection(
        totalUnread: 0,
        totalStarred: 0,
        starredUnread: 0,
        feedUnreadCounts: [:],
        tags: []
    )
}

// MARK: - Visibility policy

/// Determines which tags are shown in the sidebar based on their provisional status and the total tag count.
enum SidebarTagVisibilityPolicy {
    /// When the total number of tags exceeds this threshold, provisional tags are hidden from the sidebar.
    static let provisionalHiddenThreshold = 30

    /// Returns the subset of tags that should be displayed in the sidebar.
    ///
    /// When the total tag count is at or below the threshold, all tags are visible.
    /// When the total tag count exceeds the threshold, provisional tags are hidden.
    ///
    /// The integer literal 30 here must match `provisionalHiddenThreshold`. It is written
    /// as a literal to avoid a main-actor isolation crossing from nonisolated call sites.
    nonisolated static func visibleTags(from allTags: [SidebarTagItem]) -> [SidebarTagItem] {
        guard allTags.count > 30 else { return allTags }
        return allTags.filter { $0.isProvisional == false }
    }
}
