//
//  DebugIssuesView.swift
//  Mercury
//
//  Created by Codex on 2026/2/11.
//

import SwiftUI

struct DebugIssuesView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Debug Issues")
                    .font(.title3)
                Spacer()
                Button("Clear") {
                    appModel.taskCenter.clearDebugIssues()
                }
                .disabled(appModel.taskCenter.debugIssues.isEmpty)
                Button("Done") {
                    dismiss()
                }
            }

            if appModel.taskCenter.debugIssues.isEmpty {
                Text("No debug issues recorded.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appModel.taskCenter.debugIssues) { issue in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(issue.title)
                            .font(.headline)
                        Text(issue.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(Self.timeFormatter.string(from: issue.createdAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 320)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}
