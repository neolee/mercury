import Foundation
import Testing
@testable import Mercury

@Suite("Export Multiple Digest Sheet View Model", .serialized)
@MainActor
struct ExportMultipleDigestSheetViewModelTests {
    @Test("Preview order follows provided entry order")
    @MainActor
    func previewOrderFollowsProvidedEntryOrder() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: DigestViewModelTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entries = try await seedDigestEntries(using: appModel, count: 2)
            let orderedEntryIDs = try entries.reversed().map(requiredEntryID)
            let viewModel = ExportMultipleDigestSheetViewModel()

            await viewModel.bindIfNeeded(
                appModel: appModel,
                orderedEntryIDs: orderedEntryIDs,
                bundle: DigestResourceBundleLocator.bundle()
            )

            let copied = viewModel.prepareCopyMarkdown()
            let firstEntryIndex = copied?.range(of: "## Digest Entry 2")?.lowerBound
            let secondEntryIndex = copied?.range(of: "## Digest Entry 1")?.lowerBound

            #expect(viewModel.canCopyDigest == true)
            #expect(copied?.contains("## Digest Entry 2") == true)
            #expect(copied?.contains("## Digest Entry 1") == true)
            #expect(firstEntryIndex != nil)
            #expect(secondEntryIndex != nil)
            #expect(firstEntryIndex! < secondEntryIndex!)
        }
    }

    @Test("Expired export folder access keeps copy available while export stays disabled")
    @MainActor
    func expiredExportFolderAccessKeepsCopyAvailable() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: DigestViewModelTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entries = try await seedDigestEntries(using: appModel, count: 2)
            let orderedEntryIDs = try entries.map(requiredEntryID)
            let expiredStatus = makeDigestExportDirectoryStatus(
                url: URL(fileURLWithPath: "/tmp/digest", isDirectory: true),
                issue: .accessDenied,
                underlyingErrorDescription: "Security-scoped resource access was denied: /tmp/digest",
                startAccessingSucceeded: false,
                writeProbeSucceeded: nil
            )
            let viewModel = ExportMultipleDigestSheetViewModel(
                exportDirectoryStatusProvider: { expiredStatus }
            )

            await viewModel.bindIfNeeded(
                appModel: appModel,
                orderedEntryIDs: orderedEntryIDs,
                bundle: DigestResourceBundleLocator.bundle()
            )

            let copied = viewModel.prepareCopyMarkdown()

            #expect(viewModel.exportDirectoryIsAvailable == false)
            #expect(viewModel.canCopyDigest == true)
            #expect(viewModel.canExportDigest == false)
            #expect(viewModel.exportDirectoryRecoveryMessage == "Digest export folder access has expired. Re-select it in Settings > Digest.")
            #expect(copied?.contains("## Digest Entry 1") == true)
        }
    }

    @Test("Bind uses shared digest template loader and keeps preview available")
    @MainActor
    func bindUsesSharedDigestTemplateLoader() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: DigestViewModelTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entries = try await seedDigestEntries(using: appModel, count: 2)
            let orderedEntryIDs = try entries.map(requiredEntryID)
            var loaderCallCount = 0
            let viewModel = ExportMultipleDigestSheetViewModel(
                exportDirectoryStatusProvider: { .notConfigured },
                digestTemplateLoader: { _, onNotice in
                    loaderCallCount += 1
                    await onNotice("Custom Export Multiple Digest template is invalid. Using built-in template.")
                    let store = DigestTemplateStore()
                    try store.loadBuiltInTemplates(bundle: DigestResourceBundleLocator.bundle())
                    return try store.template(id: DigestPolicy.multipleMarkdownTemplateID)
                }
            )

            await viewModel.bindIfNeeded(
                appModel: appModel,
                orderedEntryIDs: orderedEntryIDs,
                bundle: DigestResourceBundleLocator.bundle()
            )

            #expect(loaderCallCount == 1)
            #expect(viewModel.templateNoticeMessage == "Custom Export Multiple Digest template is invalid. Using built-in template.")
            #expect(viewModel.canCopyDigest == true)
        }
    }
}
