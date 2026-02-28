//
//  DebugIssue.swift
//  Mercury
//

import Foundation

struct AppUserError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let createdAt: Date
}

enum DebugIssueCategory: String, CaseIterable {
    case all
    case task
    case reader
    case general

    var label: String {
        switch self {
        case .all: return "All"
        case .task: return "Task"
        case .reader: return "Reader"
        case .general: return "General"
        }
    }
}

struct DebugIssue: Identifiable {
    let id = UUID()
    let category: DebugIssueCategory
    let title: String
    let detail: String
    let createdAt: Date
}
