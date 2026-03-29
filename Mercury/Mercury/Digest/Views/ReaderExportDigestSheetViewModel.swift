import Combine
import Foundation

@MainActor
final class ReaderExportDigestSheetViewModel: ObservableObject {
    @Published private(set) var articleTitle = ""
    @Published private(set) var articleAuthor = ""
    @Published private(set) var articleURL = ""
    @Published private(set) var digestTitle = ""
    @Published private(set) var exportFileName = ""
    @Published private(set) var exportDirectoryPath = ""

    @Published var includeSummary = false
    @Published var summaryTargetLanguage = AgentLanguageOption.english.code
    @Published var summaryDetailLevel: SummaryDetailLevel = .medium
    @Published private(set) var summaryText = ""
    @Published private(set) var isSummaryLoading = false
    @Published private(set) var isSummaryRunning = false
    @Published private(set) var summaryState: SummaryState = .idle

    @Published var includeNote = false
    @Published private(set) var noteDraftText = ""
    @Published private(set) var noteSaveState: DigestNoteSaveState = .idle

    @Published private(set) var exportState: ExportState = .idle

    private weak var appModel: AppModel?
    private var entry: Entry?
    private var notePersistedText = ""
    private var noteHasPersistedRecord = false
    private var noteAutoFlushTask: Task<Void, Never>?
    private var summaryTaskId: UUID?
    private var summaryHasPersistedRecordForCurrentSlot = false
    private var singleMarkdownTemplate: DigestTemplate?
    private var didReportTemplateLoadFailure = false
    private var exportDirectoryURL: URL?
    private var exportDate = Date()
    private var loadReaderHTML: ((Entry, EffectiveReaderTheme) async -> ReaderBuildResult)?
    private var effectiveReaderTheme: EffectiveReaderTheme?
    private var bundle: Bundle = LanguageManager.shared.bundle

    deinit {
        noteAutoFlushTask?.cancel()
    }

    enum SummaryState: Equatable {
        case idle
        case loading
        case generating
        case saved
        case cancelled
        case failed(String?)
    }

    enum ExportState: Equatable {
        case idle
        case exporting
        case failed(String)
    }

    var exportPreviewMarkdown: String {
        guard let content = currentMarkdownContent() else {
            return ""
        }

        if let singleMarkdownTemplate {
            do {
                return DigestExportPolicy.normalizeMarkdownLayout(try singleMarkdownTemplate.render(
                    context: DigestExportPolicy.singleEntryTemplateContext(content, bundle: bundle)
                ))
            } catch {
                reportTemplateRenderFailureOnce(error)
                return ""
            }
        }

        return ""
    }

    var canExportDigest: Bool {
        guard exportDirectoryIsAvailable else {
            return false
        }
        guard exportPreviewMarkdown.isEmpty == false else {
            return false
        }
        if includeSummary {
            let normalizedSummary = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedSummary.isEmpty == false, isSummaryRunning == false else {
                return false
            }
        }
        return true
    }

    var canCopyDigest: Bool {
        exportPreviewMarkdown.isEmpty == false && exportState != .exporting
    }

    var exportDirectoryIsAvailable: Bool {
        DigestExportPathStore.isConfiguredDirectoryAvailable()
    }

    func bindIfNeeded(
        appModel: AppModel,
        entry: Entry,
        loadReaderHTML: @escaping (Entry, EffectiveReaderTheme) async -> ReaderBuildResult,
        effectiveReaderTheme: EffectiveReaderTheme,
        bundle: Bundle
    ) async {
        guard self.entry?.id != entry.id || self.appModel == nil else {
            refreshExportDirectory()
            return
        }

        self.appModel = appModel
        self.entry = entry
        self.loadReaderHTML = loadReaderHTML
        self.effectiveReaderTheme = effectiveReaderTheme
        self.bundle = bundle
        exportDate = Date()
        exportState = .idle

        loadTemplateIfNeeded(appModel: appModel)
        await loadDigestProjection(fallbackEntry: entry)
        refreshExportDirectory()
        await loadLatestSummaryState()
        await loadNoteState()
    }

    func refreshExportDirectory() {
        exportDirectoryURL = DigestExportPathStore.resolveDirectory()
        exportDirectoryPath = exportDirectoryURL?.path ?? ""
        exportFileName = DigestExportPolicy.makeSingleEntryFileName(
            digestTitle: digestTitle,
            exportDate: exportDate
        )
    }

    func updateNoteDraftText(_ newValue: String) {
        noteDraftText = newValue
        noteSaveState = .saving
        scheduleNoteAutoFlush()
    }

    func handleSheetClose() async {
        cancelScheduledNoteFlush()
        if let snapshot = currentNoteSnapshot() {
            await commitEntryNote(snapshot: snapshot, trigger: .panelClose)
        }
    }

    func handleAppBackgrounding() async {
        cancelScheduledNoteFlush()
        if let snapshot = currentNoteSnapshot() {
            await commitEntryNote(snapshot: snapshot, trigger: .appBackground)
        }
        refreshExportDirectory()
    }

    func handleSummaryControlChange() async {
        guard isSummaryRunning == false else { return }
        await loadSummaryRecordForCurrentSlot()
    }

    func generateSummary() async {
        guard let appModel, let entry, let entryId = entry.id else { return }
        guard isSummaryRunning == false else { return }

        summaryTaskId = nil
        isSummaryRunning = true
        isSummaryLoading = false
        summaryState = .generating
        summaryText = ""
        exportState = .idle

        let sourceText = await resolveSummarySourceText(for: entry)
        let request = SummaryRunRequest(
            entryId: entryId,
            sourceText: sourceText,
            targetLanguage: summaryTargetLanguage,
            detailLevel: summaryDetailLevel
        )

        _ = await appModel.startSummaryRun(request: request) { [weak self] event in
            guard let self else { return }
            await self.receiveSummaryRunEvent(event)
        }
    }

    func cancelSummary() {
        guard let summaryTaskId, let appModel else { return }
        Task {
            await appModel.cancelTask(summaryTaskId)
        }
    }

    func clearSummary() async {
        guard let appModel, let entryId = entry?.id else { return }

        do {
            _ = try await appModel.clearSummaryRecord(
                entryId: entryId,
                targetLanguage: summaryTargetLanguage,
                detailLevel: summaryDetailLevel
            )
            summaryText = ""
            summaryHasPersistedRecordForCurrentSlot = false
            summaryState = .idle
        } catch {
            summaryState = .failed(error.localizedDescription)
            appModel.reportDebugIssue(
                title: "Clear Summary Failed",
                detail: [
                    "entryId=\(entryId)",
                    "targetLanguage=\(summaryTargetLanguage)",
                    "detailLevel=\(summaryDetailLevel.rawValue)",
                    "error=\(error.localizedDescription)"
                ].joined(separator: "\n"),
                category: .task
            )
        }
    }

    func exportDigest() async -> URL? {
        exportState = .exporting
        refreshExportDirectory()

        do {
            let directory = try DigestExportPolicy.validateExportDirectory(exportDirectoryURL)
            guard let markdown = await prepareRenderedMarkdown() else {
                exportState = .failed(
                    String(localized: "Digest markdown is empty.", bundle: bundle)
                )
                return nil
            }

            let fileURL = try DigestExportPolicy.writeMarkdownFile(
                content: markdown,
                preferredFileName: exportFileName,
                directory: directory
            )
            exportState = .idle
            return fileURL
        } catch {
            exportState = .failed(error.localizedDescription)
            appModel?.reportDebugIssue(
                title: "Export Digest Failed",
                detail: error.localizedDescription,
                category: .task
            )
            return nil
        }
    }

    func prepareCopyMarkdown() async -> String? {
        await prepareRenderedMarkdown()
    }

    private func prepareRenderedMarkdown() async -> String? {
        cancelScheduledNoteFlush()
        if let snapshot = currentNoteSnapshot() {
            await commitEntryNote(snapshot: snapshot, trigger: .shareOrExportConsumption)
        }

        let rendered = exportPreviewMarkdown
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
            digestTitle = fallbackTitle
            refreshExportDirectory()
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
                digestTitle = articleTitle
                refreshExportDirectory()
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
        digestTitle = fallbackTitle
        refreshExportDirectory()
    }

    private func loadTemplateIfNeeded(appModel: AppModel) {
        guard singleMarkdownTemplate == nil else { return }

        let store = DigestTemplateStore()
        do {
            try store.loadBuiltInTemplates()
            singleMarkdownTemplate = try store.template(id: DigestPolicy.singleMarkdownTemplateID)
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

    private func reportTemplateRenderFailureOnce(_ error: Error) {
        guard didReportTemplateLoadFailure == false else { return }
        didReportTemplateLoadFailure = true
        appModel?.reportDebugIssue(
            title: "Render Digest Template Failed",
            detail: error.localizedDescription,
            category: .task
        )
    }

    private func loadLatestSummaryState() async {
        guard let appModel, let entryId = entry?.id else { return }

        isSummaryLoading = true
        summaryState = .loading
        defer { isSummaryLoading = false }

        do {
            if let latest = try await appModel.loadLatestSummaryRecord(entryId: entryId) {
                summaryTargetLanguage = latest.result.targetLanguage
                summaryDetailLevel = latest.result.detailLevel
                summaryText = latest.result.text
                summaryHasPersistedRecordForCurrentSlot = true
                includeSummary = true
                summaryState = .saved
                return
            }

            let defaults = appModel.loadSummaryAgentDefaults()
            summaryTargetLanguage = defaults.targetLanguage
            summaryDetailLevel = defaults.detailLevel
            summaryText = ""
            summaryHasPersistedRecordForCurrentSlot = false
            includeSummary = false
            summaryState = .idle
        } catch {
            summaryText = ""
            summaryHasPersistedRecordForCurrentSlot = false
            includeSummary = false
            summaryState = .failed(error.localizedDescription)
            appModel.reportDebugIssue(
                title: "Load Summary Failed",
                detail: [
                    "entryId=\(entryId)",
                    "error=\(error.localizedDescription)"
                ].joined(separator: "\n"),
                category: .task
            )
        }
    }

    private func loadSummaryRecordForCurrentSlot() async {
        guard let appModel, let entryId = entry?.id else { return }

        isSummaryLoading = true
        summaryState = .loading
        defer { isSummaryLoading = false }

        do {
            let record = try await appModel.loadSummaryRecord(
                entryId: entryId,
                targetLanguage: summaryTargetLanguage,
                detailLevel: summaryDetailLevel
            )
            summaryText = record?.result.text ?? ""
            summaryHasPersistedRecordForCurrentSlot = record != nil
            summaryState = record == nil ? .idle : .saved
        } catch {
            summaryText = ""
            summaryHasPersistedRecordForCurrentSlot = false
            summaryState = .failed(error.localizedDescription)
            appModel.reportDebugIssue(
                title: "Load Summary Failed",
                detail: [
                    "entryId=\(entryId)",
                    "targetLanguage=\(summaryTargetLanguage)",
                    "detailLevel=\(summaryDetailLevel.rawValue)",
                    "error=\(error.localizedDescription)"
                ].joined(separator: "\n"),
                category: .task
            )
        }
    }

    private func handleSummaryRunEvent(_ event: SummaryRunEvent) {
        switch event {
        case .started(let taskId):
            summaryTaskId = taskId
            isSummaryRunning = true
            summaryState = .generating

        case .notice:
            break

        case .token(let token):
            isSummaryRunning = true
            summaryText += token

        case .terminal(let outcome):
            summaryTaskId = nil
            isSummaryRunning = false

            switch outcome {
            case .succeeded:
                Task { await loadSummaryRecordForCurrentSlot() }
            case .cancelled:
                summaryState = .cancelled
                if summaryHasPersistedRecordForCurrentSlot == false {
                    summaryText = ""
                }
            case .failed(_, let message), .timedOut(_, let message):
                summaryState = .failed(message)
                if summaryHasPersistedRecordForCurrentSlot == false {
                    summaryText = ""
                }
            }
        }
    }

    private func receiveSummaryRunEvent(_ event: SummaryRunEvent) async {
        handleSummaryRunEvent(event)
    }

    private func resolveSummarySourceText(for entry: Entry) async -> String {
        let fallback = fallbackSummarySourceText(for: entry)
        guard let appModel, let entryId = entry.id else {
            return fallback
        }

        if let markdown = try? await appModel.availableReaderMarkdown(entryId: entryId) {
            return markdown
        }

        if let loadReaderHTML, let effectiveReaderTheme {
            _ = await loadReaderHTML(entry, effectiveReaderTheme)
            if let markdown = try? await appModel.availableReaderMarkdown(entryId: entryId) {
                return markdown
            }
        }

        return fallback
    }

    private func fallbackSummarySourceText(for entry: Entry) -> String {
        let summary = (entry.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty == false {
            return summary
        }

        let title = (entry.title ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled" : title
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
            guard let snapshot = currentNoteSnapshot() else { return }
            await commitEntryNote(snapshot: snapshot, trigger: .autoFlush)
        }
    }

    private func cancelScheduledNoteFlush() {
        noteAutoFlushTask?.cancel()
        noteAutoFlushTask = nil
    }

    private func currentNoteSnapshot() -> DigestNoteEditorSnapshot? {
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
                    noteSaveState = snapshot.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    snapshot.hasPersistedRecord == false ? .idle : .saved
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

    private func currentMarkdownContent() -> DigestSingleEntryMarkdownContent? {
        DigestExportPolicy.makeSingleEntryMarkdownContent(
            articleTitle: articleTitle,
            articleAuthor: articleAuthor,
            articleURL: articleURL,
            summaryText: includeSummary ? summaryText : nil,
            summaryTargetLanguage: includeSummary ? summaryTargetLanguage : nil,
            summaryDetailLevel: includeSummary ? summaryDetailLevel : nil,
            noteText: includeNote ? noteDraftText : nil,
            exportDate: exportDate
        )
    }
}
