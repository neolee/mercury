import Combine
import Foundation

@MainActor
final class ReaderExportDigestSheetViewModel: ObservableObject {
    let noteController = DigestNoteController()

    @Published private(set) var articleTitle = ""
    @Published private(set) var articleAuthor = ""
    @Published private(set) var articleURL = ""
    @Published private(set) var digestTitle = ""
    @Published private(set) var exportFileName = ""
    @Published private(set) var exportDirectoryPath = ""
    @Published private(set) var exportDirectoryStatus: DigestExportDirectoryStatus = .notConfigured
    @Published private(set) var templateNoticeMessage: String?

    @Published var includeSummary = false
    @Published var summaryTargetLanguage = AgentLanguageOption.english.code
    @Published var summaryDetailLevel: SummaryDetailLevel = .medium
    @Published private(set) var summaryText = ""
    @Published private(set) var isSummaryLoading = false
    @Published private(set) var isSummaryRunning = false
    @Published private(set) var summaryState: SummaryState = .idle

    @Published var includeNote = false

    @Published private(set) var exportState: ExportState = .idle

    private weak var appModel: AppModel?
    private var entry: Entry?
    private var summaryTaskId: UUID?
    private var summaryHasPersistedRecordForCurrentSlot = false
    private var singleMarkdownTemplate: DigestTemplate?
    private var didReportTemplateLoadFailure = false
    private var exportDate = Date()
    private var loadReaderHTML: ((Entry, EffectiveReaderTheme) async -> ReaderBuildResult)?
    private var effectiveReaderTheme: EffectiveReaderTheme?
    private var bundle: Bundle = LanguageManager.shared.bundle
    private var cancellables: Set<AnyCancellable> = []
    private let exportDirectoryStatusProvider: () -> DigestExportDirectoryStatus
    private let digestTemplateLoader: (AppModel, @escaping (String) async -> Void) async throws -> DigestTemplate

    init(
        exportDirectoryStatusProvider: @escaping () -> DigestExportDirectoryStatus = { DigestExportPathStore.currentDirectoryStatus() },
        digestTemplateLoader: @escaping (AppModel, @escaping (String) async -> Void) async throws -> DigestTemplate = { appModel, onNotice in
            try await appModel.loadDigestTemplate(config: .exportDigest, onNotice: onNotice)
        }
    ) {
        self.exportDirectoryStatusProvider = exportDirectoryStatusProvider
        self.digestTemplateLoader = digestTemplateLoader
        noteController.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
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

    var noteDraftText: String {
        noteController.draftText
    }

    var noteSaveState: DigestNoteSaveState {
        noteController.saveState
    }

    var exportDirectoryIsAvailable: Bool {
        exportDirectoryStatus.isAvailable
    }

    var exportDirectoryRecoveryMessage: String? {
        exportDirectoryStatus.localizedRecoveryMessage(bundle: bundle)
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
        noteController.bind(appModel: appModel)
        self.loadReaderHTML = loadReaderHTML
        self.effectiveReaderTheme = effectiveReaderTheme
        self.bundle = bundle
        exportDate = Date()
        exportState = .idle
        templateNoticeMessage = nil

        await loadTemplateIfNeeded(appModel: appModel)
        let projection = await DigestSingleEntryProjectionLoader.load(appModel: appModel, entry: entry)
        articleTitle = projection.articleTitle
        articleURL = projection.articleURL
        articleAuthor = projection.articleAuthor
        digestTitle = projection.digestTitle
        refreshExportDirectory()
        await loadLatestSummaryState()
        await noteController.load(entryId: entry.id)
        includeNote = noteController.hasPersistedRecord
    }

    func refreshExportDirectory() {
        exportDirectoryStatus = exportDirectoryStatusProvider()
        exportDirectoryPath = exportDirectoryStatus.path
        exportFileName = DigestExportPolicy.makeSingleEntryFileName(
            digestTitle: digestTitle,
            exportDate: exportDate
        )
    }

    func updateNoteDraftText(_ newValue: String) {
        noteController.updateDraftText(newValue)
    }

    func handleSheetClose() async {
        noteController.cancelScheduledFlush()
        await noteController.commitCurrent(trigger: .panelClose)
    }

    func handleAppBackgrounding() async {
        noteController.cancelScheduledFlush()
        await noteController.commitCurrent(trigger: .appBackground)
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

        guard exportDirectoryStatus.isAvailable, let exportDirectoryURL = exportDirectoryStatus.resolvedURL else {
            exportState = .failed(localizedExportDirectoryFailureMessage())
            reportExportDirectoryAccessFailure(operation: "single_export")
            return nil
        }

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
                detail: (
                    exportDirectoryStatus.diagnostic
                        .debugLines(operation: "single_export", preferredFileName: exportFileName)
                    + ["writeError=\(error.localizedDescription)"]
                )
                .joined(separator: "\n"),
                category: .task
            )
            return nil
        }
    }

    private func localizedExportDirectoryFailureMessage() -> String {
        exportDirectoryStatus.localizedRecoveryMessage(bundle: bundle)
            ?? String(
                localized: "Digest export needs a valid local export folder. Configure it in Settings > Digest.",
                bundle: bundle
            )
    }

    private func reportExportDirectoryAccessFailure(operation: String) {
        appModel?.reportDebugIssue(
            title: "Digest Export Access Validation Failed",
            detail: exportDirectoryStatus.diagnostic
                .debugLines(operation: operation, preferredFileName: exportFileName)
                .joined(separator: "\n"),
            category: .task
        )
    }

    func prepareCopyMarkdown() async -> String? {
        await prepareRenderedMarkdown()
    }

    private func prepareRenderedMarkdown() async -> String? {
        noteController.cancelScheduledFlush()
        await noteController.commitCurrent(trigger: .shareOrExportConsumption)

        let rendered = exportPreviewMarkdown
        guard rendered.isEmpty == false else {
            return nil
        }
        return rendered
    }

    private func loadTemplateIfNeeded(appModel: AppModel) async {
        guard singleMarkdownTemplate == nil else { return }

        do {
            singleMarkdownTemplate = try await digestTemplateLoader(appModel, { [weak self] message in
                await MainActor.run {
                    self?.templateNoticeMessage = message
                }
            })
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

            let defaults = await appModel.loadEffectiveSummaryAgentDefaults()
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

    private func currentMarkdownContent() -> DigestSingleEntryMarkdownContent? {
        DigestExportPolicy.makeSingleEntryMarkdownContent(
            articleTitle: articleTitle,
            articleAuthor: articleAuthor,
            articleURL: articleURL,
            summaryText: includeSummary ? summaryText : nil,
            summaryTargetLanguage: includeSummary ? summaryTargetLanguage : nil,
            summaryDetailLevel: includeSummary ? summaryDetailLevel : nil,
            noteText: includeNote ? noteController.draftText : nil,
            exportDate: exportDate
        )
    }
}
