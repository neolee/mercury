//
//  SidebarView.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI

struct SidebarView<StatusView: View>: View {
    let feeds: [Feed]
    @Binding var selectedFeedId: Int64?
    let onAddFeed: () -> Void
    let onImportOPML: () -> Void
    let onSyncNow: () -> Void
    let onExportOPML: () -> Void
    let onEditFeed: (Feed) -> Void
    let onDeleteFeed: (Feed) -> Void
    let statusView: StatusView

    init(
        feeds: [Feed],
        selectedFeedId: Binding<Int64?>,
        onAddFeed: @escaping () -> Void,
        onImportOPML: @escaping () -> Void,
        onSyncNow: @escaping () -> Void,
        onExportOPML: @escaping () -> Void,
        onEditFeed: @escaping (Feed) -> Void,
        onDeleteFeed: @escaping (Feed) -> Void,
        @ViewBuilder statusView: () -> StatusView
    ) {
        self.feeds = feeds
        self._selectedFeedId = selectedFeedId
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
            Text("Feeds")
                .font(.headline)
            Spacer()
            Menu {
                Button("Add Feed…", action: onAddFeed)
                Button("Import OPML…", action: onImportOPML)
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)

            Menu {
                Button("Sync Now", action: onSyncNow)
                Divider()
                Button("Export OPML…", action: onExportOPML)
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
        List(selection: $selectedFeedId) {
            ForEach(feeds) { feed in
                HStack(spacing: 8) {
                    Text(feed.title ?? feed.feedURL)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if feed.unreadCount > 0 {
                        Text("\(feed.unreadCount)")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                .tag(feed.id)
                .contextMenu {
                    Button("Edit…") {
                        onEditFeed(feed)
                    }
                    Button("Delete…", role: .destructive) {
                        onDeleteFeed(feed)
                    }
                }
            }
        }
    }
}
