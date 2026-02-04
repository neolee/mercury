//
//  ReaderDebug.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import Foundation

struct ReaderDebugLogEntry: Identifiable {
    let id = UUID()
    let stage: String
    let durationMs: Int?
    let message: String
}

struct ReaderDebugSnapshot {
    let entryId: Int64
    let urlString: String
    let rawHTML: String?
    let readabilityContent: String?
    let markdown: String?
}

struct ReaderBuildResult {
    let html: String?
    let logs: [ReaderDebugLogEntry]
    let snapshot: ReaderDebugSnapshot?
    let errorMessage: String?
}

enum ReaderBuildError: Error {
    case timeout(String)
    case invalidURL
    case emptyContent
}
