//
//  DebugIssuesView.swift
//  Mercury
//
//  Created by Codex on 2026/2/11.
//

import SwiftUI
import AppKit

struct DebugIssuesView: View {
    @EnvironmentObject private var taskCenter: TaskCenter
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: DebugIssueCategory = .all

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("", selection: $selectedCategory) {
                    ForEach(DebugIssueCategory.allCases, id: \.self) { category in
                        Text(category.label).tag(category)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
                Spacer()
                Button("Copy") {
                    copyToPasteboard()
                }
                .disabled(filteredIssues.isEmpty)
                Button("Clear") {
                    taskCenter.clearDebugIssues()
                }
                .disabled(taskCenter.debugIssues.isEmpty)
                Button("Done") {
                    dismiss()
                }
            }

            if filteredIssues.isEmpty {
                Text("No debug issues recorded.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredIssues) { issue in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("[\(issue.category.label)] \(issue.title)")
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
        .frame(minWidth: 560, minHeight: 460)
    }

    private var filteredIssues: [DebugIssue] {
        if selectedCategory == .all {
            return taskCenter.debugIssues
        }
        return taskCenter.debugIssues.filter { $0.category == selectedCategory }
    }

    private func copyToPasteboard() {
        let text = filteredIssues.map { issue in
            [
                "[\(issue.category.label)] \(issue.title)",
                issue.detail,
                Self.timeFormatter.string(from: issue.createdAt)
            ].joined(separator: "\n")
        }.joined(separator: "\n\n---\n\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}
