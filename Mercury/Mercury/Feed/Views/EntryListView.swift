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
    let mutationLock: BatchMutationLock
    @Binding var unreadOnly: Bool
    let showFeedSource: Bool
    @Binding var selectedEntryId: Int64?
    let selectedEntry: EntryListItem?
    let isMultipleDigestSelectionMode: Bool
    let multipleDigestSelectedEntryIDs: Set<Int64>
    let onLoadMore: () -> Void
    let onMarkAllRead: () -> Void
    let onMarkAllUnread: () -> Void
    let onMarkSelectedRead: () -> Void
    let onMarkSelectedUnread: () -> Void
    let onToggleStar: (EntryListItem) -> Void
    let onBeginMultipleDigestSelection: () -> Void
    let onToggleMultipleDigestSelection: (Int64) -> Void
    let onCancelMultipleDigestSelection: () -> Void
    let onConfirmMultipleDigestSelection: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            List(selection: selectionBinding) {
                ForEach(entries) { entry in
                    EntryListRowView(
                        entry: entry,
                        showFeedSource: showFeedSource,
                        isSelected: selectedEntryId == entry.id,
                        isMultipleDigestSelectionMode: isMultipleDigestSelectionMode,
                        isMultipleDigestSelected: multipleDigestSelectedEntryIDs.contains(entry.id),
                        mutationLock: mutationLock,
                        onToggleStar: {
                            onToggleStar(entry)
                        },
                        onToggleMultipleDigestSelection: {
                            onToggleMultipleDigestSelection(entry.id)
                        }
                    )
                    .tag(entry.id)
                }

                if hasMore || isLoadingMore {
                    loadMoreFooter
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if isMultipleDigestSelectionMode {
            multipleDigestSelectionHeader
        } else {
            defaultHeader
        }
    }

    private var defaultHeader: some View {
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
                    .disabled(
                        mutationLock.blocksEntryMutations
                            || !MarkReadPolicy.canMarkRead(selectedEntry: selectedEntry)
                    )
                Button(action: onMarkSelectedUnread) { Text("Mark Unread", bundle: bundle) }
                    .disabled(
                        mutationLock.blocksEntryMutations
                            || !MarkReadPolicy.canMarkUnread(selectedEntry: selectedEntry)
                    )
                Divider()
                Button(action: onMarkAllRead) { Text("Mark All Read", bundle: bundle) }
                    .disabled(mutationLock.blocksEntryMutations)
                Button(action: onMarkAllUnread) { Text("Mark All Unread", bundle: bundle) }
                    .disabled(mutationLock.blocksEntryMutations)
                Divider()
                Button(action: onBeginMultipleDigestSelection) { Text("Export Multiple Digest...", bundle: bundle) }
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
    }

    private var multipleDigestSelectionHeader: some View {
        HStack(spacing: 12) {
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {
                onCancelMultipleDigestSelection()
            }

            Text(selectionStatusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button(String(localized: "Continue", bundle: bundle)) {
                onConfirmMultipleDigestSelection()
            }
            .disabled(multipleDigestSelectedEntryIDs.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var loadMoreFooter: some View {
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

    private var selectionBinding: Binding<Int64?> {
        if isMultipleDigestSelectionMode {
            return .constant(selectedEntryId)
        }
        return $selectedEntryId
    }

    private var selectionStatusText: String {
        String(
            format: String(localized: "%lld selected", bundle: bundle),
            Int64(multipleDigestSelectedEntryIDs.count)
        )
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
    let isMultipleDigestSelectionMode: Bool
    let isMultipleDigestSelected: Bool
    let mutationLock: BatchMutationLock
    let onToggleStar: () -> Void
    let onToggleMultipleDigestSelection: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isMultipleDigestSelectionMode {
                multipleDigestSelectionButton
            }

            unreadIndicator

            VStack(alignment: .leading, spacing: 4) {
                titleLine
                if showFeedSource, let feedTitle = entry.feedSourceTitle {
                    Text(feedTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                metadataLine
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var unreadIndicator: some View {
        Circle()
            .fill(entry.isRead ? Color.clear : Color.accentColor)
            .frame(width: 6, height: 6)
            .padding(.top, 6)
    }

    private var titleLine: some View {
        Text(entry.title ?? String(localized: "(Untitled)", bundle: bundle))
            .fontWeight(entry.isRead ? .regular : .semibold)
            .foregroundStyle(entry.isRead ? .secondary : .primary)
            .lineLimit(2)
    }

    private var metadataLine: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(EntryListView.dateFormatter.string(from: entry.publishedAt ?? entry.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)

            if isMultipleDigestSelectionMode == false {
                Spacer(minLength: 6)
                starButton
            }
        }
    }

    private var multipleDigestSelectionButton: some View {
        Button(action: onToggleMultipleDigestSelection) {
            Image(systemName: isMultipleDigestSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(isMultipleDigestSelected ? Color.accentColor : .secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
    }

    private var starButton: some View {
        Button(action: onToggleStar) {
            Image(systemName: entry.isStarred ? "star.fill" : "star")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(entry.isStarred ? Color.accentColor : .secondary)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .opacity(shouldShowStarButton ? 1 : 0)
        .disabled(shouldShowStarButton == false || mutationLock.blocksEntryMutations)
    }

    private var shouldShowStarButton: Bool {
        entry.isStarred || isHovering || isSelected
    }
}
