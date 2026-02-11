//
//  ImportOPMLSheet.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI

struct ImportOPMLSheet: View {
    @Binding var replaceExisting: Bool
    @Binding var forceSiteNameAsFeedTitle: Bool
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import OPML")
                .font(.title3)
            Toggle("Replace existing feeds", isOn: $replaceExisting)
            Toggle("Force site name as feed title", isOn: $forceSiteNameAsFeedTitle)
            Text("Merge is the default and will keep your current subscriptions. Replace will delete all existing feeds first.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("When enabled, Mercury will try to fetch each feed's site name and use it as title. If fetching fails, original OPML title is kept.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Import") {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
