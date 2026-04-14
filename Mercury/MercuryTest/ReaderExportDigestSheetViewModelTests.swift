import Foundation
import Testing
@testable import Mercury

@Suite("Reader Export Digest Sheet View Model", .serialized)
@MainActor
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

    @Test("Bind uses shared digest template loader and keeps preview available")
    @MainActor
    func bindUsesSharedDigestTemplateLoader() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: DigestViewModelTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await seedDigestEntry(using: appModel)
            var loaderCallCount = 0
            let viewModel = ReaderExportDigestSheetViewModel(
                exportDirectoryStatusProvider: { .notConfigured },
                digestTemplateLoader: { _, onNotice in
                    loaderCallCount += 1
                    await onNotice("Custom Export Digest template is invalid. Using built-in template.")
                    let store = DigestTemplateStore()
                    try store.loadBuiltInTemplates(bundle: DigestResourceBundleLocator.bundle())
                    return try store.template(id: DigestPolicy.singleMarkdownTemplateID)
                }
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

            #expect(loaderCallCount == 1)
            #expect(viewModel.templateNoticeMessage == "Custom Export Digest template is invalid. Using built-in template.")
            #expect(viewModel.canCopyDigest == true)
        }
    }
}
