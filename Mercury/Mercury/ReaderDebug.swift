//
//  ReaderDebug.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import Foundation

struct ReaderBuildResult {
    let html: String?
    let errorMessage: String?
}

enum ReaderBuildError: Error {
    case timeout(String)
    case invalidURL
    case emptyContent
}
