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
    @Binding var selectedEntryId: Int64?

    var body: some View {
        List(selection: $selectedEntryId) {
            if isLoading {
                ProgressView()
            }

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
        .navigationTitle("Entries")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
