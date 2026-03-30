import Combine
import Foundation

@MainActor
final class ReaderShareDigestSheetViewModel: ObservableObject {
    let noteController = DigestNoteController()

    @Published private(set) var articleTitle = ""
    @Published private(set) var articleAuthor = ""
    @Published private(set) var articleURL = ""
    @Published private(set) var templateNoticeMessage: String?
    @Published var includeNote = false

    private weak var appModel: AppModel?
    private var entry: Entry?
    private var singleTextTemplate: DigestTemplate?
    private var didReportTemplateLoadFailure = false
    private var cancellables: Set<AnyCancellable> = []
    private let digestTemplateLoader: (AppModel, @escaping (String) async -> Void) async throws -> DigestTemplate

    init(
        digestTemplateLoader: @escaping (AppModel, @escaping (String) async -> Void) async throws -> DigestTemplate = { appModel, onNotice in
            try await appModel.loadDigestTemplate(config: .shareDigest, onNotice: onNotice)
        }
    ) {
        self.digestTemplateLoader = digestTemplateLoader
        noteController.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var sharePreviewText: String {
        guard let content = DigestComposition.singleEntryTextShareContent(
            articleTitle: articleTitle,
            articleAuthor: articleAuthor,
            articleURL: articleURL,
            noteText: noteController.draftText,
            includeNote: includeNote
        ) else {
            return ""
        }

        if let singleTextTemplate {
            do {
                return try singleTextTemplate.render(
                    context: DigestComposition.singleEntryTextTemplateContext(content)
                )
            } catch {
                reportTemplateRenderFailureOnce(error)
                return ""
            }
        }

        return ""
    }

    var canShareDigest: Bool {
        sharePreviewText.isEmpty == false
    }

    var noteDraftText: String {
        noteController.draftText
    }

    var noteSaveState: DigestNoteSaveState {
        noteController.saveState
    }

    func bindIfNeeded(appModel: AppModel, entry: Entry) async {
        guard self.entry?.id != entry.id || self.appModel == nil else {
            return
        }

        self.appModel = appModel
        self.entry = entry
        noteController.bind(appModel: appModel)
        templateNoticeMessage = nil
        await loadTemplateIfNeeded(appModel: appModel)
        let projection = await DigestSingleEntryProjectionLoader.load(appModel: appModel, entry: entry)
        articleTitle = projection.articleTitle
        articleURL = projection.articleURL
        articleAuthor = projection.articleAuthor
        await noteController.load(entryId: entry.id)
        includeNote = noteController.hasPersistedRecord
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
        noteController.cancelScheduledFlush()
        await noteController.commitCurrent(trigger: .shareOrExportConsumption)

        let rendered = sharePreviewText
        guard rendered.isEmpty == false else {
            return nil
        }
        return rendered
    }

    private func loadTemplateIfNeeded(appModel: AppModel) async {
        guard singleTextTemplate == nil else { return }

        do {
            singleTextTemplate = try await digestTemplateLoader(appModel, { [weak self] message in
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
}
