//
//  AppModel+Reader.swift
//  Mercury
//

import Foundation
extension AppModel {
    func readerBuildResult(for entry: Entry, theme: EffectiveReaderTheme) async -> ReaderBuildResult {
        let output = await readerBuildUseCase.run(for: entry, theme: theme)
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
