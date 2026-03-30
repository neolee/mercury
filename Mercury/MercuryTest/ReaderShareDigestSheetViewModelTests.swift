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
}
