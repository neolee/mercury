import Combine
import Foundation

@MainActor
final class ExportMultipleDigestSheetViewModel: ObservableObject {
    @Published private(set) var selectedEntries: [DigestMultipleEntryProjectionData] = []
    @Published private(set) var digestTitle = ""
    @Published private(set) var exportFileName = ""
    @Published private(set) var exportDirectoryPath = ""

    @Published var includeSummary = false
    @Published var includeNote = false

    @Published private(set) var exportState: ExportState = .idle

    private weak var appModel: AppModel?
    private var orderedEntryIDs: [Int64] = []
    private var multipleMarkdownTemplate: DigestTemplate?
    private var didReportTemplateLoadFailure = false
    private var exportDirectoryURL: URL?
    private var exportDate = Date()
    private var bundle: Bundle = LanguageManager.shared.bundle

    enum ExportState: Equatable {
        case idle
        case exporting
        case failed(String)
    }

    var exportDirectoryIsAvailable: Bool {
        DigestExportPathStore.isConfiguredDirectoryAvailable()
    }

    var canCopyDigest: Bool {
        exportPreviewMarkdown.isEmpty == false && exportState != .exporting
    }

    var canExportDigest: Bool {
        guard exportDirectoryIsAvailable else {
            return false
        }
        return exportPreviewMarkdown.isEmpty == false && exportState != .exporting
    }

    var exportPreviewMarkdown: String {
        guard let content = currentMarkdownContent() else {
            return ""
        }

        guard let multipleMarkdownTemplate else {
            return ""
        }

        do {
            return DigestExportPolicy.normalizeMarkdownLayout(
                try multipleMarkdownTemplate.render(
                    context: DigestExportPolicy.multipleEntryTemplateContext(content, bundle: bundle)
                )
            )
        } catch {
            reportTemplateRenderFailureOnce(error)
            return ""
        }
    }

    func bindIfNeeded(
        appModel: AppModel,
        orderedEntryIDs: [Int64],
        bundle: Bundle
    ) async {
        guard self.orderedEntryIDs != orderedEntryIDs || self.appModel == nil else {
            refreshExportDirectory()
            return
        }

        self.appModel = appModel
        self.orderedEntryIDs = orderedEntryIDs
        self.bundle = bundle
        exportDate = Date()
        exportState = .idle

        loadTemplateIfNeeded(appModel: appModel)
        selectedEntries = await DigestMultipleEntryProjectionLoader.load(appModel: appModel, entryIDs: orderedEntryIDs)
        refreshExportDirectory()
    }

    func refreshExportDirectory() {
        exportDirectoryURL = DigestExportPathStore.resolveDirectory()
        exportDirectoryPath = exportDirectoryURL?.path ?? ""
        digestTitle = DigestExportPolicy.makeMultipleEntryDigestTitle(exportDate: exportDate)
        exportFileName = DigestExportPolicy.makeMultipleEntryFileName(exportDate: exportDate)
    }

    func handleAppBackgrounding() {
        refreshExportDirectory()
    }

    func prepareCopyMarkdown() -> String? {
        let rendered = exportPreviewMarkdown
        guard rendered.isEmpty == false else {
            return nil
        }
        return rendered
    }

    func exportDigest() async -> URL? {
        exportState = .exporting
        refreshExportDirectory()

        do {
            let directory = try DigestExportPolicy.validateExportDirectory(exportDirectoryURL)
            guard let markdown = prepareCopyMarkdown() else {
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
                title: "Export Multiple Digest Failed",
                detail: error.localizedDescription,
                category: .task
            )
            return nil
        }
    }

    private func currentMarkdownContent() -> DigestMultipleEntryMarkdownContent? {
        DigestExportPolicy.makeMultipleEntryMarkdownContent(
            entries: selectedEntries.map {
                DigestMultipleEntryMarkdownEntryContent(
                    articleTitle: $0.articleTitle,
                    articleAuthor: $0.articleAuthor,
                    articleURL: $0.articleURL,
                    summaryText: $0.summaryText,
                    noteText: $0.noteText
                )
            },
            includeSummary: includeSummary,
            includeNote: includeNote,
            exportDate: exportDate
        )
    }

    private func loadTemplateIfNeeded(appModel: AppModel) {
        guard multipleMarkdownTemplate == nil else { return }

        let store = DigestTemplateStore()
        do {
            try store.loadBuiltInTemplates(bundle: DigestResourceBundleLocator.bundle())
            multipleMarkdownTemplate = try store.template(id: DigestPolicy.multipleMarkdownTemplateID)
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
