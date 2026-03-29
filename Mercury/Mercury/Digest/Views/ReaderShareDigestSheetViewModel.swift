import Combine
import Foundation

@MainActor
final class ReaderShareDigestSheetViewModel: ObservableObject {
    @Published private(set) var articleTitle = ""
    @Published private(set) var articleAuthor = ""
    @Published private(set) var articleURL = ""
    @Published var includeNote = false
    @Published private(set) var noteDraftText = ""
    @Published private(set) var noteSaveState: DigestNoteSaveState = .idle

    private weak var appModel: AppModel?
    private var entry: Entry?
    private var notePersistedText = ""
    private var noteHasPersistedRecord = false
    private var noteAutoFlushTask: Task<Void, Never>?
    private var singleTextTemplate: DigestTemplate?
    private var didReportTemplateLoadFailure = false

    deinit {
        noteAutoFlushTask?.cancel()
    }

    var sharePreviewText: String {
        guard let content = DigestComposition.singleEntryTextShareContent(
            articleTitle: articleTitle,
            articleAuthor: articleAuthor,
            articleURL: articleURL,
            noteText: noteDraftText,
            includeNote: includeNote
        ) else {
            return ""
        }

        if let singleTextTemplate {
            return singleTextTemplate.render(
                context: DigestComposition.singleEntryTextTemplateContext(content)
            )
        }

        return DigestComposition.renderSingleEntryTextShareFallback(content)
    }

    var canShareDigest: Bool {
        sharePreviewText.isEmpty == false
    }

    func bindIfNeeded(appModel: AppModel, entry: Entry) async {
        guard self.entry?.id != entry.id || self.appModel == nil else {
            return
        }

        self.appModel = appModel
        self.entry = entry
        loadTemplateIfNeeded(appModel: appModel)
        await loadDigestProjection(fallbackEntry: entry)

        await loadNoteState()
    }

    func updateNoteDraftText(_ newValue: String) {
        noteDraftText = newValue
        noteSaveState = .saving
        scheduleNoteAutoFlush()
    }

    func handleSheetClose() async {
        cancelScheduledNoteFlush()
        guard let snapshot = currentSnapshot() else { return }
        await commitEntryNote(snapshot: snapshot, trigger: .panelClose)
    }

    func handleAppBackgrounding() async {
        cancelScheduledNoteFlush()
        guard let snapshot = currentSnapshot() else { return }
        await commitEntryNote(snapshot: snapshot, trigger: .appBackground)
    }

    func prepareShareItems() async -> [Any] {
        guard let rendered = await prepareRenderedDigestText() else {
            return []
        }

        var items: [Any] = []
        if let url = URL(string: articleURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
            items.append(url as NSURL)
        }
        items.append(rendered as NSString)
        return items
    }

    func prepareCopyText() async -> String? {
        await prepareRenderedDigestText()
    }

    private func prepareRenderedDigestText() async -> String? {
        cancelScheduledNoteFlush()
        if let snapshot = currentSnapshot() {
            await commitEntryNote(snapshot: snapshot, trigger: .shareOrExportConsumption)
        }

        let rendered = sharePreviewText
        guard rendered.isEmpty == false else {
            return nil
        }
        return rendered
    }

    private func loadDigestProjection(fallbackEntry entry: Entry) async {
        let fallbackTitle = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackURL = (entry.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackAuthor = DigestComposition.resolvedAuthor(
            entryAuthor: entry.author,
            feedTitle: nil
        )

        guard let appModel, let entryId = entry.id else {
            articleTitle = fallbackTitle
            articleURL = fallbackURL
            articleAuthor = fallbackAuthor
            return
        }

        do {
            if let projection = try await appModel.loadSingleEntryDigestProjection(entryId: entryId) {
                articleTitle = (projection.articleTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                articleURL = (projection.articleURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                articleAuthor = DigestComposition.resolvedAuthor(
                    entryAuthor: projection.entryAuthor,
                    readabilityByline: projection.readabilityByline,
                    feedTitle: projection.feedTitle
                )
                return
            }
        } catch {
            appModel.reportDebugIssue(
                title: "Load Digest Projection Failed",
                detail: [
                    "entryId=\(entryId)",
                    "error=\(error.localizedDescription)"
                ].joined(separator: "\n"),
                category: .task
            )
        }

        articleTitle = fallbackTitle
        articleURL = fallbackURL
        articleAuthor = fallbackAuthor
    }

    private func loadTemplateIfNeeded(appModel: AppModel) {
        guard singleTextTemplate == nil else { return }

        let store = DigestTemplateStore()
        do {
            try store.loadBuiltInTemplates()
            singleTextTemplate = try store.template(id: DigestPolicy.singleTextTemplateID)
        } catch {
            guard didReportTemplateLoadFailure == false else { return }
            didReportTemplateLoadFailure = true
            appModel.reportDebugIssue(
                title: "Load Digest Template Failed",
                detail: error.localizedDescription,
                category: .task
            )
        }
    }

    private func loadNoteState() async {
        guard let appModel, let entryId = entry?.id else { return }

        do {
            let note = try await appModel.loadEntryNote(entryId: entryId)
            noteDraftText = note?.markdownText ?? ""
            notePersistedText = note?.markdownText ?? ""
            noteHasPersistedRecord = note != nil
            includeNote = note != nil
            noteSaveState = note == nil ? .idle : .saved
        } catch {
            noteDraftText = ""
            notePersistedText = ""
            noteHasPersistedRecord = false
            includeNote = false
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

    private func scheduleNoteAutoFlush() {
        cancelScheduledNoteFlush()
        noteAutoFlushTask = Task {
            try? await Task.sleep(for: DigestPolicy.autoFlushDelay)
            guard Task.isCancelled == false else { return }
            guard let snapshot = currentSnapshot() else { return }
            await commitEntryNote(snapshot: snapshot, trigger: .autoFlush)
        }
    }

    private func cancelScheduledNoteFlush() {
        noteAutoFlushTask?.cancel()
        noteAutoFlushTask = nil
    }

    private func currentSnapshot() -> DigestNoteEditorSnapshot? {
        guard let entryId = entry?.id else { return nil }

        return DigestNoteEditorSnapshot(
            entryId: entryId,
            draftText: noteDraftText,
            persistedText: notePersistedText,
            hasPersistedRecord: noteHasPersistedRecord
        )
    }

    private func commitEntryNote(snapshot: DigestNoteEditorSnapshot, trigger: EntryNotePersistenceTrigger) async {
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
                if noteDraftText == snapshot.draftText {
                    noteSaveState = snapshot.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && snapshot.hasPersistedRecord == false
                        ? .idle
                        : .saved
                }

            case .upsert(let markdownText):
                _ = try await appModel.upsertEntryNote(entryId: snapshot.entryId, markdownText: markdownText)
                notePersistedText = markdownText
                noteHasPersistedRecord = true
                if noteDraftText == snapshot.draftText {
                    noteSaveState = .saved
                }

            case .delete:
                _ = try await appModel.deleteEntryNote(entryId: snapshot.entryId)
                notePersistedText = ""
                noteHasPersistedRecord = false
                if noteDraftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    noteSaveState = .idle
                }
            }
        } catch {
            if noteDraftText == snapshot.draftText {
                noteSaveState = .failed
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
