import Foundation
import Testing
@testable import Mercury

@Suite("Export Multiple Digest Sheet View Model", .serialized)
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
}
