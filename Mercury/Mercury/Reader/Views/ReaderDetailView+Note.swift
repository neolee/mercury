import Foundation
import SwiftUI

enum ReaderNoteSaveState: Equatable {
    case idle
    case saving
    case saved
    case failed
}

struct ReaderNoteEditorSnapshot: Equatable {
    let entryId: Int64
    let draftText: String
    let persistedText: String
    let hasPersistedRecord: Bool
}

extension ReaderDetailView {
    var noteDraftBinding: Binding<String> {
        Binding(
            get: { noteDraftText },
            set: { newValue in
                updateNoteDraftText(newValue)
            }
        )
    }

    var notePanelStatusText: String? {
        switch noteSaveState {
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
           noteEntryId != selectedEntryId {
            Task {
                await loadNoteState(for: selectedEntryId)
            }
        }
    }

    func handleSelectedEntryChange(from oldEntryId: Int64?, to newEntryId: Int64?) {
        let previousSnapshot = currentNoteSnapshot(entryIdOverride: oldEntryId)
        cancelScheduledNoteFlush()

        activeToolbarPanel = nil
        noteEntryId = newEntryId
        noteDraftText = ""
        notePersistedText = ""
        noteHasPersistedRecord = false
        noteSaveState = .idle

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
        guard let entryId else {
            noteEntryId = nil
            noteDraftText = ""
            notePersistedText = ""
            noteHasPersistedRecord = false
            noteSaveState = .idle
            return
        }

        do {
            let note = try await appModel.loadEntryNote(entryId: entryId)
            guard selectedEntry?.id == entryId else {
                return
            }
            if noteEntryId == entryId,
               noteDraftText != notePersistedText {
                return
            }

            noteEntryId = entryId
            noteDraftText = note?.markdownText ?? ""
            notePersistedText = note?.markdownText ?? ""
            noteHasPersistedRecord = note != nil
            noteSaveState = note == nil ? .idle : .saved
        } catch {
            guard selectedEntry?.id == entryId else {
                return
            }

            noteEntryId = entryId
            noteDraftText = ""
            notePersistedText = ""
            noteHasPersistedRecord = false
            noteSaveState = .failed
            appModel.reportDebugIssue(
                title: "Load Entry Note Failed",
                detail: [
                    "entryId=\(entryId)",
                    "error=\(error.localizedDescription)"
                ].joined(separator: "\n"),
                category: .task
            )
        }
    }

    func updateNoteDraftText(_ newValue: String) {
        noteDraftText = newValue
        noteSaveState = .saving
        scheduleNoteAutoFlush()
    }

    func scheduleNoteAutoFlush() {
        cancelScheduledNoteFlush()
        noteAutoFlushTask = Task {
            try? await Task.sleep(for: ReaderNotePolicy.autoFlushDelay)
            guard Task.isCancelled == false else {
                return
            }
            guard let snapshot = currentNoteSnapshot() else {
                return
            }
            await commitEntryNote(snapshot: snapshot, trigger: .autoFlush)
        }
    }

    func cancelScheduledNoteFlush() {
        noteAutoFlushTask?.cancel()
        noteAutoFlushTask = nil
    }

    func currentNoteSnapshot(entryIdOverride: Int64? = nil) -> ReaderNoteEditorSnapshot? {
        let resolvedEntryId = entryIdOverride ?? noteEntryId ?? selectedEntry?.id
        guard let resolvedEntryId else {
            return nil
        }

        return ReaderNoteEditorSnapshot(
            entryId: resolvedEntryId,
            draftText: noteDraftText,
            persistedText: notePersistedText,
            hasPersistedRecord: noteHasPersistedRecord
        )
    }

    func commitEntryNote(snapshot: ReaderNoteEditorSnapshot, trigger: EntryNotePersistenceTrigger) async {
        let decision = EntryNotePersistencePolicy.decision(
            for: EntryNotePersistenceSnapshot(
                draftText: snapshot.draftText,
                persistedText: snapshot.persistedText,
                hasPersistedRecord: snapshot.hasPersistedRecord
            ),
            trigger: trigger
        )

        do {
            switch decision {
            case .noChange:
                await MainActor.run {
                    if noteEntryId == snapshot.entryId,
                       noteDraftText == snapshot.draftText {
                        noteSaveState = snapshot.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && snapshot.hasPersistedRecord == false
                            ? .idle
                            : .saved
                    }
                }

            case .upsert(let markdownText):
                _ = try await appModel.upsertEntryNote(entryId: snapshot.entryId, markdownText: markdownText)
                await MainActor.run {
                    guard noteEntryId == snapshot.entryId else {
                        return
                    }

                    notePersistedText = markdownText
                    noteHasPersistedRecord = true
                    if noteDraftText == snapshot.draftText {
                        noteSaveState = .saved
                    }
                }

            case .delete:
                _ = try await appModel.deleteEntryNote(entryId: snapshot.entryId)
                await MainActor.run {
                    guard noteEntryId == snapshot.entryId else {
                        return
                    }

                    notePersistedText = ""
                    noteHasPersistedRecord = false
                    if noteDraftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        noteSaveState = .idle
                    }
                }
            }
        } catch {
            await MainActor.run {
                if noteEntryId == snapshot.entryId,
                   noteDraftText == snapshot.draftText {
                    noteSaveState = .failed
                }
            }
            appModel.reportDebugIssue(
                title: "Persist Entry Note Failed",
                detail: [
                    "entryId=\(snapshot.entryId)",
                    "trigger=\(String(describing: trigger))",
                    "error=\(error.localizedDescription)"
                ].joined(separator: "\n"),
                category: .task
            )
        }
    }
}
