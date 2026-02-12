//
//  EntryListView.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI

struct EntryListView: View {
    let entries: [Entry]
    let isLoading: Bool
    @Binding var unreadOnly: Bool
    let showFeedSource: Bool
    let feedTitleByEntryId: [Int64: String]
    @Binding var selectedEntryId: Int64?
    let onMarkAllRead: () -> Void
    let onMarkAllUnread: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Entries")
                    .font(.headline)
                ProgressView()
                    .controlSize(.small)
                    .opacity(isLoading ? 1 : 0)
                    .frame(width: 16)
                    .accessibilityHidden(!isLoading)
                Spacer()
                Menu {
                    Button("Mark All Read", action: onMarkAllRead)
                    Button("Mark All Unread", action: onMarkAllUnread)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(entries.isEmpty)
                .help("Batch actions for loaded entries")

                Toggle(isOn: $unreadOnly) {
                    Label("Unread", systemImage: unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
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
                            Text(entry.title ?? "(Untitled)")
                                .fontWeight(entry.isRead ? .regular : .semibold)
                                .foregroundStyle(entry.isRead ? .secondary : .primary)
                                .lineLimit(2)
                            if showFeedSource, let entryId = entry.id, let feedTitle = feedTitleByEntryId[entryId] {
                                Text(feedTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let publishedAt = entry.publishedAt {
                                Text(Self.dateFormatter.string(from: publishedAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tag(entry.id)
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
