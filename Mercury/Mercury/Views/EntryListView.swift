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
    @Binding var unreadOnly: Bool
    let showFeedSource: Bool
    @Binding var selectedEntryId: Int64?
    let onLoadMore: () -> Void
    let onMarkAllRead: () -> Void
    let onMarkAllUnread: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Entries", bundle: bundle)
                    .font(.headline)
                ProgressView()
                    .controlSize(.small)
                    .opacity(isLoading ? 1 : 0)
                    .frame(width: 16)
                    .accessibilityHidden(!isLoading)
                Spacer()
                Menu {
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
                            Text(Self.dateFormatter.string(from: entry.publishedAt ?? entry.createdAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
