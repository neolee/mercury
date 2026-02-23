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
    @Environment(\.localizationBundle) var bundle

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import OPML", bundle: bundle)
                .font(.title3)
            Toggle(isOn: $replaceExisting) { Text("Replace existing feeds", bundle: bundle) }
            Toggle(isOn: $forceSiteNameAsFeedTitle) { Text("Force site name as feed title", bundle: bundle) }
            Text("Merge is the default and will keep your current subscriptions. Replace will delete all existing feeds first.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("When enabled, Mercury will try to fetch each feed's site name and use it as title. If fetching fails, original OPML title is kept.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(action: { dismiss() }) { Text("Cancel", bundle: bundle) }
                Button(action: { onConfirm(); dismiss() }) { Text("Import", bundle: bundle) }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
