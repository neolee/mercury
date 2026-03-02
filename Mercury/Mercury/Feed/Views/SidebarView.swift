//
//  SidebarView.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI

enum SidebarSection: Hashable {
    case feeds
    case tags
}

struct SidebarView<StatusView: View>: View {
    @Environment(\.localizationBundle) var bundle

    let feeds: [Feed]
    let entryStore: EntryStore
    let totalUnreadCount: Int
    let totalStarredCount: Int
    let starredUnreadCount: Int
    @Binding var sidebarSection: SidebarSection
    @Binding var tagMatchMode: EntryStore.TagMatchMode
    @Binding var selectedFeed: FeedSelection
    @Binding var selectedTagIds: Set<Int64>
    let refreshToken: Int
    let onAddFeed: () -> Void
    let onImportOPML: () -> Void
    let onSyncNow: () -> Void
    let onExportOPML: () -> Void
    let onEditFeed: (Feed) -> Void
    let onDeleteFeed: (Feed) -> Void
    let statusView: StatusView

    @StateObject private var tagListViewModel: TagListViewModel

    private let maxSelectedTags = 5

    init(
        feeds: [Feed],
        entryStore: EntryStore,
        totalUnreadCount: Int,
        totalStarredCount: Int,
        starredUnreadCount: Int,
        sidebarSection: Binding<SidebarSection>,
        tagMatchMode: Binding<EntryStore.TagMatchMode>,
        selectedFeed: Binding<FeedSelection>,
        selectedTagIds: Binding<Set<Int64>>,
        refreshToken: Int,
        onAddFeed: @escaping () -> Void,
        onImportOPML: @escaping () -> Void,
        onSyncNow: @escaping () -> Void,
        onExportOPML: @escaping () -> Void,
        onEditFeed: @escaping (Feed) -> Void,
        onDeleteFeed: @escaping (Feed) -> Void,
        @ViewBuilder statusView: () -> StatusView
    ) {
        self.feeds = feeds
        self.entryStore = entryStore
        self.totalUnreadCount = totalUnreadCount
        self.totalStarredCount = totalStarredCount
        self.starredUnreadCount = starredUnreadCount
        self._sidebarSection = sidebarSection
        self._tagMatchMode = tagMatchMode
        self._selectedFeed = selectedFeed
        self._selectedTagIds = selectedTagIds
        self.refreshToken = refreshToken
        self.onAddFeed = onAddFeed
        self.onImportOPML = onImportOPML
        self.onSyncNow = onSyncNow
        self.onExportOPML = onExportOPML
        self.onEditFeed = onEditFeed
        self.onDeleteFeed = onDeleteFeed
        self.statusView = statusView()
        self._tagListViewModel = StateObject(wrappedValue: TagListViewModel(entryStore: entryStore))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if sidebarSection == .feeds {
                feedList
            } else {
                tagList
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                statusView
            }
            .padding(8)
        }
        .frame(minWidth: 220)
        .task(id: tagListViewModel.searchText) {
            guard sidebarSection == .tags else { return }
            await tagListViewModel.loadNonProvisionalTags()
        }
        .task(id: sidebarSection) {
            guard sidebarSection == .tags else { return }
            await tagListViewModel.loadNonProvisionalTags()
        }
        .task(id: refreshToken) {
            guard sidebarSection == .tags else { return }
            await tagListViewModel.loadNonProvisionalTags()
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Picker("", selection: $sidebarSection) {
                Text("Feeds", bundle: bundle).tag(SidebarSection.feeds)
                Text("Tags", bundle: bundle).tag(SidebarSection.tags)
            }
            .pickerStyle(.segmented)

            HStack {
                Text(sidebarSection == .feeds ? "Feeds" : "Tags", bundle: bundle)
                    .font(.headline)
                Spacer()

                if sidebarSection == .feeds {
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
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var feedList: some View {
        List(selection: $selectedFeed) {
            ForEach(virtualFeedRows) { item in
                SidebarFeedRow(
                    title: item.title,
                    titleSecondarySuffix: item.titleSecondarySuffix,
                    badgeCount: item.badgeCount,
                    iconSystemName: item.iconSystemName
                )
                .tag(item.selection)
            }

            ForEach(feedRows, id: \.id) { tuple in
                let feed = tuple.feed
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

    private var tagList: some View {
        VStack(spacing: 6) {
            TextField(String(localized: "Search tags", bundle: bundle), text: $tagListViewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.top, 6)

            ZStack {
                Picker(String(localized: "Match", bundle: bundle), selection: $tagMatchMode) {
                    Text("Any", bundle: bundle).tag(EntryStore.TagMatchMode.any)
                    Text("All", bundle: bundle).tag(EntryStore.TagMatchMode.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .help(String(localized: "Match mode for selected tags", bundle: bundle))

                HStack {
                    Spacer()
                    if selectedTagIds.isEmpty == false {
                        Button {
                            selectedTagIds.removeAll()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Clear selected tags", bundle: bundle))
                    }
                }
            }
            .padding(.horizontal, 10)

            if tagListViewModel.tags.isEmpty, tagListViewModel.isLoading == false {
                VStack(spacing: 8) {
                    Text("No tags yet", bundle: bundle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(tagListViewModel.tags, id: \.id) { tag in
                        if let tagId = tag.id {
                            Button {
                                toggleTagSelection(tagId: tagId)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: selectedTagIds.contains(tagId) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selectedTagIds.contains(tagId) ? Color.accentColor : .secondary)
                                    HStack(spacing: 2) {
                                        Text(tag.name)
                                            .lineLimit(1)
                                        Text("(\(tag.usageCount))")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    let unreadCount = tagListViewModel.unreadCounts[tagId] ?? 0
                                    if unreadCount > 0 {
                                        Text("\(unreadCount)")
                                            .font(.caption)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                            .disabled(selectedTagIds.contains(tagId) == false && selectedTagIds.count >= maxSelectedTags)
                        }
                    }
                }
            }

            Text(String(format: String(localized: "Selected: %lld / 5", bundle: bundle), selectedTagIds.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
    }

    private var virtualFeedRows: [VirtualFeedRow] {
        [
            VirtualFeedRow(
                selection: .all,
                title: String(localized: "All Feeds", bundle: bundle),
                titleSecondarySuffix: nil,
                badgeCount: totalUnreadCount,
                iconSystemName: "tray.full"
            ),
            VirtualFeedRow(
                selection: .starred,
                title: String(localized: "Starred", bundle: bundle),
                titleSecondarySuffix: "(\(totalStarredCount))",
                badgeCount: starredUnreadCount,
                iconSystemName: "star.fill"
            )
        ]
    }

    private var feedRows: [(id: Int64, feed: Feed)] {
        feeds.compactMap { feed in
            guard let feedId = feed.id else { return nil }
            return (id: feedId, feed: feed)
        }
    }

    private func toggleTagSelection(tagId: Int64) {
        if selectedTagIds.contains(tagId) {
            selectedTagIds.remove(tagId)
            return
        }
        guard selectedTagIds.count < maxSelectedTags else { return }
        selectedTagIds.insert(tagId)
    }

}

private struct VirtualFeedRow: Identifiable {
    let selection: FeedSelection
    let title: String
    let titleSecondarySuffix: String?
    let badgeCount: Int
    let iconSystemName: String

    var id: FeedSelection { selection }
}

private struct SidebarFeedRow: View {
    let title: String
    let titleSecondarySuffix: String?
    let badgeCount: Int
    let iconSystemName: String?

    init(
        title: String,
        titleSecondarySuffix: String? = nil,
        badgeCount: Int,
        iconSystemName: String? = nil
    ) {
        self.title = title
        self.titleSecondarySuffix = titleSecondarySuffix
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

            HStack(spacing: 2) {
                Text(title)
                    .lineLimit(1)
                if let titleSecondarySuffix {
                    Text(titleSecondarySuffix)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

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
