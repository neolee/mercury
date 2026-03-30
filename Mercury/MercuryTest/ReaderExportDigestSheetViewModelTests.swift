import Foundation
import Testing
@testable import Mercury

@Suite("Reader Export Digest Sheet View Model", .serialized)
struct ReaderExportDigestSheetViewModelTests {
    @Test("Missing export directory keeps copy available while export stays disabled")
    @MainActor
    func missingExportDirectoryKeepsCopyAvailable() async throws {
        let existingDirectory = DigestExportPathStore.resolveDirectory()
        defer {
            if let existingDirectory {
                DigestExportPathStore.saveDirectory(existingDirectory)
            } else {
                DigestExportPathStore.clearDirectory()
            }
        }
        DigestExportPathStore.clearDirectory()

        try await AppModelTestHarness.withInMemory(
            credentialStore: DigestViewModelTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await seedDigestEntry(using: appModel)
            let viewModel = ReaderExportDigestSheetViewModel()

            await viewModel.bindIfNeeded(
                appModel: appModel,
                entry: entry,
                loadReaderHTML: { _, _ in ReaderBuildResult(html: nil, errorMessage: nil) },
                effectiveReaderTheme: ReaderThemeResolver.resolve(
                    presetID: .classic,
                    mode: .forceLight,
                    isSystemDark: false,
                    override: nil
                ),
                bundle: DigestResourceBundleLocator.bundle()
            )

            let copied = await viewModel.prepareCopyMarkdown()

            #expect(viewModel.exportDirectoryIsAvailable == false)
            #expect(viewModel.canCopyDigest == true)
            #expect(viewModel.canExportDigest == false)
            #expect(copied?.contains("**Source**") == true)
        }
    }
}
