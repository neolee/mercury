import SwiftUI

extension ContentView {
    func beginMultipleDigestSelectionMode() {
        autoMarkReadTask?.cancel()
        autoMarkReadTask = nil
        isMultipleDigestSelectionMode = true
        multipleDigestSelectedEntryIDs.removeAll()
    }

    func exitMultipleDigestSelectionMode() {
        guard isMultipleDigestSelectionMode else { return }
        isMultipleDigestSelectionMode = false
        multipleDigestSelectedEntryIDs.removeAll()
    }

    func toggleMultipleDigestSelection(entryId: Int64) {
        guard isMultipleDigestSelectionMode else { return }
        if multipleDigestSelectedEntryIDs.contains(entryId) {
            multipleDigestSelectedEntryIDs.remove(entryId)
        } else {
            multipleDigestSelectedEntryIDs.insert(entryId)
        }
    }

    func confirmMultipleDigestSelection() {
        let orderedEntryIDs = orderedMultipleDigestSelection(
            entryIDs: appModel.entryStore.entries.map(\.id),
            selectedEntryIDs: multipleDigestSelectedEntryIDs
        )
        guard orderedEntryIDs.isEmpty == false else { return }

        multipleDigestExportSession = MultipleDigestExportSession(orderedEntryIDs: orderedEntryIDs)
        exitMultipleDigestSelectionMode()
    }

    func orderedMultipleDigestSelection(
        entryIDs: [Int64],
        selectedEntryIDs: Set<Int64>
    ) -> [Int64] {
        entryIDs.filter { selectedEntryIDs.contains($0) }
    }
}
