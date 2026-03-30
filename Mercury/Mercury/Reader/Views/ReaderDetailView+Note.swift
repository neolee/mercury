import Foundation
import SwiftUI

extension ReaderDetailView {
    var noteDraftBinding: Binding<String> {
        Binding(
            get: { noteController.draftText },
            set: { newValue in
                updateNoteDraftText(newValue)
            }
        )
    }

    var notePanelStatusText: String? {
        switch noteController.saveState {
        case .idle:
            return nil
        case .saving:
            return String(localized: "Saving...", bundle: bundle)
        case .saved:
            return String(localized: "Saved", bundle: bundle)
        case .failed:
            return String(localized: "Save failed", bundle: bundle)
        }
    }

    func toggleToolbarPanel(_ panel: ReaderToolbarPanelKind) {
        let nextPanel: ReaderToolbarPanelKind? = activeToolbarPanel == panel ? nil : panel
        transitionToolbarPanel(to: nextPanel, trigger: .panelClose)
    }

    func closeActiveToolbarPanel(trigger: EntryNotePersistenceTrigger = .panelClose) {
        transitionToolbarPanel(to: nil, trigger: trigger)
    }

    func transitionToolbarPanel(to nextPanel: ReaderToolbarPanelKind?, trigger: EntryNotePersistenceTrigger) {
        let currentPanel = activeToolbarPanel
        if currentPanel == .note && currentPanel != nextPanel {
            cancelScheduledNoteFlush()
            if let snapshot = currentNoteSnapshot() {
                Task {
                    await commitEntryNote(snapshot: snapshot, trigger: trigger)
                }
            }
        }

        activeToolbarPanel = nextPanel

        if nextPanel == .note,
           let selectedEntryId = selectedEntry?.id,
           noteController.entryId != selectedEntryId {
            Task {
                await loadNoteState(for: selectedEntryId)
            }
        }
    }

    func handleSelectedEntryChange(from oldEntryId: Int64?, to newEntryId: Int64?) {
        let previousSnapshot = currentNoteSnapshot(entryIdOverride: oldEntryId)
        cancelScheduledNoteFlush()

        activeToolbarPanel = nil
        noteController.reset(entryId: newEntryId)

        if let previousSnapshot {
            Task {
                await commitEntryNote(snapshot: previousSnapshot, trigger: .entrySwitch)
            }
        }

        if let newEntryId {
            Task {
                await loadNoteState(for: newEntryId)
            }
        }
    }

    func handleNoteAppBackgrounding() {
        cancelScheduledNoteFlush()
        guard let snapshot = currentNoteSnapshot() else {
            return
        }
        Task {
            await commitEntryNote(snapshot: snapshot, trigger: .appBackground)
        }
    }

    func loadNoteState(for entryId: Int64?) async {
        noteController.bind(appModel: appModel)
        await noteController.load(entryId: entryId)
    }

    func updateNoteDraftText(_ newValue: String) {
        noteController.updateDraftText(newValue)
    }

    func cancelScheduledNoteFlush() {
        noteController.cancelScheduledFlush()
    }

    func currentNoteSnapshot(entryIdOverride: Int64? = nil) -> DigestNoteEditorSnapshot? {
        noteController.snapshot(entryIdOverride: entryIdOverride ?? selectedEntry?.id)
    }

    func commitEntryNote(snapshot: DigestNoteEditorSnapshot, trigger: EntryNotePersistenceTrigger) async {
        noteController.bind(appModel: appModel)
        await noteController.commit(snapshot: snapshot, trigger: trigger)
    }
}
