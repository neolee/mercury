import Combine
import Foundation

@MainActor
final class BatchTaggingSheetViewModel: ObservableObject {
    @Published var scope: TagBatchSelectionScope = .pastWeek
    @Published var skipAlreadyApplied: Bool = true
    @Published var concurrency: Int = BatchTaggingPolicy.concurrencyLimit

    @Published var runId: Int64?
    @Published var taskId: UUID?
    @Published var status: TagBatchRunStatus = .configure
    @Published var totalCandidateCount: Int = 0
    @Published var processedCount: Int = 0
    @Published var succeededCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var reviewRows: [TagBatchNewTagReview] = []

    @Published var isBusy: Bool = false
    @Published var noticeMessage: String?
    @Published var errorMessage: String?

    private weak var appModel: AppModel?
    private var pollingTask: Task<Void, Never>?

    var isLifecycleLocked: Bool {
        status == .running || status == .review || status == .applying
    }

    var canStart: Bool {
        status == .configure || status == .done || status == .cancelled || status == .failed
    }

    var exceedsWarningThreshold: Bool {
        totalCandidateCount > BatchTaggingPolicy.warningThreshold
    }

    var exceedsHardSafetyCap: Bool {
        totalCandidateCount > BatchTaggingPolicy.absoluteSafetyCap
    }

    var isStartBlocked: Bool {
        totalCandidateCount <= 0 || exceedsHardSafetyCap
    }

    func bindIfNeeded(appModel: AppModel) async {
        guard self.appModel == nil else { return }
        self.appModel = appModel
        await refreshFromStore()
        await refreshCandidateCount()
        startPolling()
    }

    func refreshCandidateCount() async {
        guard let appModel else { return }
        do {
            totalCandidateCount = try await appModel.estimateTagBatchEntryCount(
                scope: scope,
                skipAlreadyApplied: skipAlreadyApplied
            )
            errorMessage = nil
        } catch {
            totalCandidateCount = 0
            errorMessage = error.localizedDescription
        }
    }

    func startRun() async {
        guard let appModel else { return }

        isBusy = true
        noticeMessage = nil
        errorMessage = nil
        defer { isBusy = false }

        do {
            let estimatedCount = try await appModel.estimateTagBatchEntryCount(
                scope: scope,
                skipAlreadyApplied: skipAlreadyApplied
            )
            totalCandidateCount = estimatedCount

            guard estimatedCount > 0 else {
                noticeMessage = "No eligible entries found for the selected scope."
                return
            }

            guard estimatedCount <= BatchTaggingPolicy.absoluteSafetyCap else {
                noticeMessage = "Estimated batch entries exceed hard safety limit (\(BatchTaggingPolicy.absoluteSafetyCap)). To reduce run risk, please narrow the scope."
                return
            }

            let entryIDs = try await appModel.fetchTagBatchEntryIDsForExecution(
                scope: scope,
                skipAlreadyApplied: skipAlreadyApplied
            )
            guard entryIDs.isEmpty == false else {
                noticeMessage = "No eligible entries found for the selected scope."
                return
            }

            let request = TagBatchStartRequest(
                scopeLabel: scope.rawValue,
                entryIDs: entryIDs,
                skipAlreadyApplied: skipAlreadyApplied,
                concurrency: concurrency
            )
            let taskId = await appModel.startTaggingBatchRun(request: request) { _ in }
            self.taskId = taskId
            await refreshFromStore()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestCancelRunning() async {
        guard let appModel, let taskId else { return }
        await appModel.requestCancelTaggingBatchRun(taskId: taskId)
        noticeMessage = "Stop requested. The run will enter review once current work settles."
    }

    func applyDecisions() async {
        guard let appModel, let runId else { return }

        isBusy = true
        noticeMessage = nil
        errorMessage = nil
        defer { isBusy = false }

        do {
            try await appModel.applyTaggingBatchRun(runId: runId) { _ in }
            await refreshFromStore()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setDecision(normalizedName: String, decision: TagBatchReviewDecision) async {
        guard let appModel, let runId else { return }
        do {
            try await appModel.setTaggingBatchReviewDecision(
                runId: runId,
                normalizedName: normalizedName,
                decision: decision
            )
            try await loadReviewRowsIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setAllReviewDecisions(decision: TagBatchReviewDecision) async {
        guard let appModel, let runId else { return }
        do {
            try await appModel.setTaggingBatchReviewDecisionForAll(runId: runId, decision: decision)
            try await loadReviewRowsIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func discardRun() async {
        guard let appModel, let runId else { return }

        isBusy = true
        noticeMessage = nil
        errorMessage = nil
        defer { isBusy = false }

        do {
            try await appModel.discardTaggingBatchRun(runId: runId)
            status = .cancelled
            reviewRows = []
            await refreshFromStore()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetToConfigure() {
        guard isLifecycleLocked == false else { return }
        runId = nil
        taskId = nil
        status = .configure
        processedCount = 0
        succeededCount = 0
        failedCount = 0
        reviewRows = []
        noticeMessage = nil
        errorMessage = nil
    }

    func resetConfigurationToDefaults() async {
        guard isLifecycleLocked == false else { return }
        scope = .pastWeek
        skipAlreadyApplied = true
        concurrency = BatchTaggingPolicy.concurrencyLimit
        noticeMessage = nil
        errorMessage = nil
        await refreshCandidateCount()
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while Task.isCancelled == false {
                guard let self else { return }
                await self.refreshFromStore()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refreshFromStore() async {
        guard let appModel else { return }

        do {
            if let active = try await appModel.loadActiveTaggingBatchRun() {
                sync(with: active)
                try await loadReviewRowsIfNeeded()
                return
            }

            if let runId, let run = try await appModel.loadTaggingBatchRun(runId: runId) {
                sync(with: run)
                if run.status == .review {
                    try await loadReviewRowsIfNeeded()
                } else if run.status == .done || run.status == .cancelled || run.status == .failed {
                    reviewRows = []
                }
                return
            }

            status = .configure
            processedCount = 0
            succeededCount = 0
            failedCount = 0
            reviewRows = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sync(with run: TagBatchRun) {
        runId = run.id
        status = run.status
        processedCount = run.processedEntries
        succeededCount = run.succeededEntries
        failedCount = run.failedEntries
        totalCandidateCount = run.totalPlannedEntries
    }

    private func loadReviewRowsIfNeeded() async throws {
        guard let appModel, let runId else {
            reviewRows = []
            return
        }
        reviewRows = try await appModel.loadTaggingBatchReviewRows(runId: runId)
    }
}
