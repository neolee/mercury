import Combine
import Foundation

@MainActor
final class DigestNoteController: ObservableObject {
    @Published private(set) var entryId: Int64?
    @Published private(set) var draftText = ""
    @Published private(set) var persistedText = ""
    @Published private(set) var hasPersistedRecord = false
    @Published private(set) var saveState: DigestNoteSaveState = .idle

    private weak var appModel: AppModel?
    private var autoFlushTask: Task<Void, Never>?

    deinit {
        autoFlushTask?.cancel()
    }

    var hasBadge: Bool {
        guard entryId != nil else { return false }
        if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        return hasPersistedRecord
    }

    func bind(appModel: AppModel) {
        self.appModel = appModel
    }

    func reset(entryId: Int64?) {
        self.entryId = entryId
        draftText = ""
        persistedText = ""
        hasPersistedRecord = false
        saveState = .idle
    }

    func load(entryId: Int64?, preserveDirtyDraftForSameEntry: Bool = true) async {
        guard let entryId else {
            reset(entryId: nil)
            return
        }
        guard let appModel else {
            reset(entryId: entryId)
            return
        }

        do {
            let note = try await appModel.loadEntryNote(entryId: entryId)
            guard self.entryId == entryId || self.entryId == nil else {
                return
            }
            if preserveDirtyDraftForSameEntry,
               self.entryId == entryId,
               draftText != persistedText {
                return
            }

            self.entryId = entryId
            draftText = note?.markdownText ?? ""
            persistedText = note?.markdownText ?? ""
            hasPersistedRecord = note != nil
            saveState = note == nil ? .idle : .saved
        } catch {
            guard self.entryId == entryId || self.entryId == nil else {
                return
            }

            self.entryId = entryId
            draftText = ""
            persistedText = ""
            hasPersistedRecord = false
            saveState = .failed
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

    func updateDraftText(_ newValue: String) {
        draftText = newValue
        saveState = .saving
        scheduleAutoFlush()
    }

    func cancelScheduledFlush() {
        autoFlushTask?.cancel()
        autoFlushTask = nil
    }

    func snapshot(entryIdOverride: Int64? = nil) -> DigestNoteEditorSnapshot? {
        let resolvedEntryId = entryIdOverride ?? entryId
        guard let resolvedEntryId else {
            return nil
        }

        return DigestNoteEditorSnapshot(
            entryId: resolvedEntryId,
            draftText: draftText,
            persistedText: persistedText,
            hasPersistedRecord: hasPersistedRecord
        )
    }

    func commitCurrent(trigger: EntryNotePersistenceTrigger) async {
        guard let snapshot = snapshot() else { return }
        await commit(snapshot: snapshot, trigger: trigger)
    }

    func commit(snapshot: DigestNoteEditorSnapshot, trigger: EntryNotePersistenceTrigger) async {
        guard let appModel else { return }

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
                if isSameActiveSnapshot(snapshot) {
                    saveState = snapshot.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        snapshot.hasPersistedRecord == false ? .idle : .saved
                }

            case .upsert(let markdownText):
                _ = try await appModel.upsertEntryNote(entryId: snapshot.entryId, markdownText: markdownText)
                guard entryId == snapshot.entryId else { return }

                persistedText = markdownText
                hasPersistedRecord = true
                if draftText == snapshot.draftText {
                    saveState = .saved
                }

            case .delete:
                _ = try await appModel.deleteEntryNote(entryId: snapshot.entryId)
                guard entryId == snapshot.entryId else { return }

                persistedText = ""
                hasPersistedRecord = false
                if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    saveState = .idle
                }
            }
        } catch {
            if isSameActiveSnapshot(snapshot) {
                saveState = .failed
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

    private func scheduleAutoFlush() {
        cancelScheduledFlush()
        autoFlushTask = Task {
            try? await Task.sleep(for: DigestPolicy.autoFlushDelay)
            guard Task.isCancelled == false else { return }
            await commitCurrent(trigger: .autoFlush)
        }
    }

    private func isSameActiveSnapshot(_ snapshot: DigestNoteEditorSnapshot) -> Bool {
        entryId == snapshot.entryId && draftText == snapshot.draftText
    }
}
