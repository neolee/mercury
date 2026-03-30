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

    @Test("Expired export folder access keeps copy available while export stays disabled")
    @MainActor
    func expiredExportFolderAccessKeepsCopyAvailable() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: DigestViewModelTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await seedDigestEntry(using: appModel)
            let expiredStatus = makeDigestExportDirectoryStatus(
                url: URL(fileURLWithPath: "/tmp/digest", isDirectory: true),
                issue: .accessDenied,
                underlyingErrorDescription: "Security-scoped resource access was denied: /tmp/digest",
                startAccessingSucceeded: false,
                writeProbeSucceeded: nil
            )
            let viewModel = ReaderExportDigestSheetViewModel(
                exportDirectoryStatusProvider: { expiredStatus }
            )

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
            #expect(viewModel.exportDirectoryRecoveryMessage == "Digest export folder access has expired. Re-select it in Settings > Digest.")
            #expect(copied?.contains("**Source**") == true)
        }
    }
}
