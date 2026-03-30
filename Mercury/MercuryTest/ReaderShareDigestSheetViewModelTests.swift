import Foundation
import Testing
@testable import Mercury

@Suite("Reader Share Digest Sheet View Model", .serialized)
struct ReaderShareDigestSheetViewModelTests {
    @Test("Prepare copy persists edited note through shared entry note storage")
    @MainActor
    func prepareCopyPersistsEditedNote() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: DigestViewModelTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await seedDigestEntry(using: appModel)
            let viewModel = ReaderShareDigestSheetViewModel()

            await viewModel.bindIfNeeded(appModel: appModel, entry: entry)
            viewModel.includeNote = true
            viewModel.updateNoteDraftText("Shared note")

            let copied = await viewModel.prepareCopyText()
            let storedNote = try await appModel.loadEntryNote(entryId: try requiredEntryID(entry))

            #expect(copied?.contains("Shared note") == true)
            #expect(storedNote?.markdownText == "Shared note")
        }
    }

    @Test("Bind uses shared digest template loader and surfaces fallback notice")
    @MainActor
    func bindUsesSharedDigestTemplateLoader() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: DigestViewModelTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await seedDigestEntry(using: appModel)
            var loaderCallCount = 0
            let viewModel = ReaderShareDigestSheetViewModel(
                digestTemplateLoader: { _, onNotice in
                    loaderCallCount += 1
                    await onNotice("Custom Share Digest template is invalid. Using built-in template.")
                    let store = DigestTemplateStore()
                    try store.loadBuiltInTemplates(bundle: DigestResourceBundleLocator.bundle())
                    return try store.template(id: DigestPolicy.singleTextTemplateID)
                }
            )

            await viewModel.bindIfNeeded(appModel: appModel, entry: entry)

            #expect(loaderCallCount == 1)
            #expect(viewModel.templateNoticeMessage == "Custom Share Digest template is invalid. Using built-in template.")
            #expect(viewModel.canShareDigest == true)
        }
    }
}
