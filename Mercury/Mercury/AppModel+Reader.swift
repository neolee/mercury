//
//  AppModel+Reader.swift
//  Mercury
//

import Foundation
extension AppModel {
    func readerBuildResult(for entry: Entry, themeId: String) async -> ReaderBuildResult {
        let output = await readerBuildUseCase.run(for: entry, themeId: themeId)
        if let debugDetail = output.debugDetail {
            reportDebugIssue(
                title: "Reader Build Failure",
                detail: debugDetail,
                category: .reader
            )
        }
        return output.result
    }
}
