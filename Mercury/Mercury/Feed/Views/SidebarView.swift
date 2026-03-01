//
//  SidebarView.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI

struct SidebarView<StatusView: View>: View {
    @Environment(\.localizationBundle) var bundle

    let feeds: [Feed]
    let totalUnreadCount: Int
    let totalStarredCount: Int
    let starredUnreadCount: Int
    @Binding var selectedFeed: FeedSelection
    let onAddFeed: () -> Void
    let onImportOPML: () -> Void
    let onSyncNow: () -> Void
    let onExportOPML: () -> Void
    let onEditFeed: (Feed) -> Void
    let onDeleteFeed: (Feed) -> Void
    let statusView: StatusView

    init(
        feeds: [Feed],
        totalUnreadCount: Int,
        totalStarredCount: Int,
        starredUnreadCount: Int,
        selectedFeed: Binding<FeedSelection>,
        onAddFeed: @escaping () -> Void,
        onImportOPML: @escaping () -> Void,
        onSyncNow: @escaping () -> Void,
        onExportOPML: @escaping () -> Void,
        onEditFeed: @escaping (Feed) -> Void,
        onDeleteFeed: @escaping (Feed) -> Void,
        @ViewBuilder statusView: () -> StatusView
    ) {
        self.feeds = feeds
        self.totalUnreadCount = totalUnreadCount
        self.totalStarredCount = totalStarredCount
        self.starredUnreadCount = starredUnreadCount
        self._selectedFeed = selectedFeed
        self.onAddFeed = onAddFeed
        self.onImportOPML = onImportOPML
        self.onSyncNow = onSyncNow
        self.onExportOPML = onExportOPML
        self.onEditFeed = onEditFeed
        self.onDeleteFeed = onDeleteFeed
        self.statusView = statusView()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            feedList
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                statusView
            }
            .padding(8)
        }
        .frame(minWidth: 220)
    }

    private var header: some View {
        HStack {
            Text("Feeds", bundle: bundle)
                .font(.headline)
            Spacer()
            Menu {
                Button(action: onAddFeed) { Text("Add Feed\u{2026}", bundle: bundle) }
                Button(action: onImportOPML) { Text("Import OPML\u{2026}", bundle: bundle) }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)

            Menu {
                Button(action: onSyncNow) { Text("Sync Now", bundle: bundle) }
                Divider()
                Button(action: onExportOPML) { Text("Export OPML\u{2026}", bundle: bundle) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var feedList: some View {
        List(selection: $selectedFeed) {
            SidebarFeedRow(
                title: String(localized: "All Feeds", bundle: bundle),
                badgeCount: totalUnreadCount,
                iconSystemName: "tray.full"
            )
            .tag(FeedSelection.all)

            SidebarFeedRow(
                title: String(format: String(localized: "Starred (%lld)", bundle: bundle), totalStarredCount),
                badgeCount: starredUnreadCount,
                iconSystemName: "star.fill"
            )
            .tag(FeedSelection.starred)

            ForEach(
                feeds.compactMap { feed -> (id: Int64, item: Feed)? in
                    guard let feedId = feed.id else { return nil }
                    return (id: feedId, item: feed)
                },
                id: \.id
            ) { tuple in
                let feed = tuple.item
                SidebarFeedRow(
                    title: feed.title ?? feed.feedURL,
                    badgeCount: feed.unreadCount
                )
                .tag(FeedSelection.feed(tuple.id))
                .contextMenu {
                    Button(action: { onEditFeed(feed) }) { Text("Edit\u{2026}", bundle: bundle) }
                    Button(role: .destructive, action: { onDeleteFeed(feed) }) { Text("Delete\u{2026}", bundle: bundle) }
                }
            }
        }
    }
}

private struct SidebarFeedRow: View {
    let title: String
    let badgeCount: Int
    let iconSystemName: String?

    init(
        title: String,
        badgeCount: Int,
        iconSystemName: String? = nil
    ) {
        self.title = title
        self.badgeCount = badgeCount
        self.iconSystemName = iconSystemName
    }

    var body: some View {
        HStack(spacing: 8) {
            if let iconSystemName {
                Image(systemName: iconSystemName)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .lineLimit(1)

            Spacer(minLength: 8)

            if badgeCount > 0 {
                Text("\(badgeCount)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }
        }
    }
}
