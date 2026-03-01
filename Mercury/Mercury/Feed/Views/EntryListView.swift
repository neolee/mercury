//
//  EntryListView.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI

struct EntryListView: View {
    @Environment(\.localizationBundle) var bundle

    let entries: [EntryListItem]
    let isLoading: Bool
    let isLoadingMore: Bool
    let hasMore: Bool
    let isStarredSelection: Bool
    @Binding var unreadOnly: Bool
    let showFeedSource: Bool
    @Binding var selectedEntryId: Int64?
    let selectedEntry: EntryListItem?
    let onLoadMore: () -> Void
    let onMarkAllRead: () -> Void
    let onMarkAllUnread: () -> Void
    let onMarkSelectedRead: () -> Void
    let onMarkSelectedUnread: () -> Void
    let onToggleStar: (EntryListItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(isStarredSelection ? "Starred" : "Entries", bundle: bundle)
                    .font(.headline)
                ProgressView()
                    .controlSize(.small)
                    .opacity(isLoading ? 1 : 0)
                    .frame(width: 16)
                    .accessibilityHidden(!isLoading)
                Spacer()
                Menu {
                    Button(action: onMarkSelectedRead) { Text("Mark Read", bundle: bundle) }
                        .disabled(!MarkReadPolicy.canMarkRead(selectedEntry: selectedEntry))
                    Button(action: onMarkSelectedUnread) { Text("Mark Unread", bundle: bundle) }
                        .disabled(!MarkReadPolicy.canMarkUnread(selectedEntry: selectedEntry))
                    Divider()
                    Button(action: onMarkAllRead) { Text("Mark All Read", bundle: bundle) }
                    Button(action: onMarkAllUnread) { Text("Mark All Unread", bundle: bundle) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(entries.isEmpty)
                .help("Batch actions for entries in current filter")

                Toggle(isOn: $unreadOnly) {
                    Label { Text("Unread", bundle: bundle) } icon: { Image(systemName: unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                }
                .toggleStyle(.button)
                .help("Show unread entries only")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List(selection: $selectedEntryId) {
                ForEach(entries) { entry in
                    EntryListRowView(
                        entry: entry,
                        showFeedSource: showFeedSource,
                        isSelected: selectedEntryId == entry.id,
                        onToggleStar: {
                            onToggleStar(entry)
                        }
                    )
                    .tag(entry.id)
                }

                if hasMore || isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                    }
                    .onAppear {
                        guard hasMore else { return }
                        guard isLoadingMore == false else { return }
                        onLoadMore()
                    }
                }
            }
        }
    }

    fileprivate static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct EntryListRowView: View {
    @Environment(\.localizationBundle) var bundle

    let entry: EntryListItem
    let showFeedSource: Bool
    let isSelected: Bool
    let onToggleStar: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if entry.isRead == false {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
            } else {
                Circle()
                    .fill(Color.clear)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title ?? String(localized: "(Untitled)", bundle: bundle))
                    .fontWeight(entry.isRead ? .regular : .semibold)
                    .foregroundStyle(entry.isRead ? .secondary : .primary)
                    .lineLimit(2)
                if showFeedSource, let feedTitle = entry.feedSourceTitle {
                    Text(feedTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(alignment: .center, spacing: 8) {
                    Text(EntryListView.dateFormatter.string(from: entry.publishedAt ?? entry.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 6)

                    Button(action: onToggleStar) {
                        Image(systemName: entry.isStarred ? "star.fill" : "star")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(entry.isStarred ? Color.accentColor : .secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .opacity(shouldShowStarButton ? 1 : 0)
                    .disabled(shouldShowStarButton == false)
                }
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var shouldShowStarButton: Bool {
        entry.isStarred || isHovering || isSelected
    }
}
