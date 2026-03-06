import Combine
import Foundation

@MainActor
final class BatchTaggingSheetViewModel: ObservableObject {
    @Published var scope: TagBatchSelectionScope = .pastWeek
    @Published var skipAlreadyApplied: Bool = true
    @Published var skipAlreadyTagged: Bool = true
    @Published var concurrency: Int = BatchTaggingPolicy.concurrencyLimit

    @Published var runId: Int64?
    @Published var taskId: UUID?
    @Published var status: TagBatchRunStatus = .configure
    @Published var totalCandidateCount: Int = 0
    @Published var processedCount: Int = 0
    @Published var succeededCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var reviewRows: [TagBatchNewTagReview] = []
    @Published var totalSuggestedTags: Int = 0
    @Published var newTagCount: Int = 0
    @Published var isStopRequested: Bool = false
    @Published var keptProposalCount: Int = 0
    @Published var discardedProposalCount: Int = 0
    @Published var insertedEntryTagCount: Int = 0
    @Published var createdTagCount: Int = 0

    @Published var isBusy: Bool = false
    @Published var noticeMessage: String?
    @Published var errorMessage: String?

    private weak var appModel: AppModel?
    private var pollingTask: Task<Void, Never>?

    var isLifecycleLocked: Bool {
        status == .running || status == .readyNext || status == .review || status == .applying
    }

    var canStart: Bool {
        status == .configure || status == .done || status == .cancelled || status == .failed
    }

    var hasReviewRequired: Bool {
        newTagCount > 0
    }

    var pendingReviewCount: Int {
        reviewRows.filter { $0.decision == .pending }.count
    }

    var hasPendingReviewDecisions: Bool {
        pendingReviewCount > 0
    }

    var completionSummary: String {
        "Batch apply completed. Processed \(processedCount), succeeded \(succeededCount), failed \(failedCount), inserted assignments \(insertedEntryTagCount), created tags \(createdTagCount), kept proposals \(keptProposalCount), discarded proposals \(discardedProposalCount)."
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
                skipAlreadyApplied: skipAlreadyApplied,
                skipAlreadyTagged: skipAlreadyTagged
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
                skipAlreadyApplied: skipAlreadyApplied,
                skipAlreadyTagged: skipAlreadyTagged
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
                skipAlreadyApplied: skipAlreadyApplied,
                skipAlreadyTagged: skipAlreadyTagged
            )
            guard entryIDs.isEmpty == false else {
                noticeMessage = "No eligible entries found for the selected scope."
                return
            }

            let request = TagBatchStartRequest(
                scopeLabel: scope.rawValue,
                entryIDs: entryIDs,
                skipAlreadyApplied: skipAlreadyApplied,
                skipAlreadyTagged: skipAlreadyTagged,
                concurrency: concurrency
            )
            let taskId = await appModel.startTaggingBatchRun(request: request) { _ in }
            self.taskId = taskId
            self.isStopRequested = false
            await refreshFromStore()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestCancelRunning() async {
        guard let appModel, let taskId else { return }
        isStopRequested = true
        await appModel.requestCancelTaggingBatchRun(taskId: taskId)
        noticeMessage = "Stop requested. Waiting for in-flight requests to finish before next actions are available."
    }

    func continueFromReadyNext() async {
        guard let appModel, let runId else { return }
        if hasReviewRequired {
            do {
                try await appModel.enterTaggingBatchReview(runId: runId)
                await refreshFromStore()
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        await applyDecisions()
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
            try await loadReviewRowsAndStatsIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setAllReviewDecisions(decision: TagBatchReviewDecision) async {
        guard let appModel, let runId else { return }
        do {
            try await appModel.setTaggingBatchReviewDecisionForAll(runId: runId, decision: decision)
            try await loadReviewRowsAndStatsIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func discardRun() async {
        guard let appModel, let runId else { return }

        guard status != .running else {
            noticeMessage = "Stop the run first and wait until all in-flight requests complete before aborting."
            return
        }

        isBusy = true
        noticeMessage = nil
        errorMessage = nil
        defer { isBusy = false }

        do {
            try await appModel.discardTaggingBatchRun(runId: runId, taskId: taskId)
            status = .cancelled
            reviewRows = []
            totalSuggestedTags = 0
            newTagCount = 0
            keptProposalCount = 0
            discardedProposalCount = 0
            insertedEntryTagCount = 0
            createdTagCount = 0
            isStopRequested = false
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
        totalSuggestedTags = 0
        newTagCount = 0
        keptProposalCount = 0
        discardedProposalCount = 0
        insertedEntryTagCount = 0
        createdTagCount = 0
        isStopRequested = false
        noticeMessage = nil
        errorMessage = nil
    }

    func resetConfigurationToDefaults() async {
        guard isLifecycleLocked == false else { return }
        scope = .pastWeek
        skipAlreadyApplied = true
        skipAlreadyTagged = true
        concurrency = BatchTaggingPolicy.concurrencyLimit
        isStopRequested = false
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
                try await loadReviewRowsAndStatsIfNeeded()
                return
            }

            if let runId, let run = try await appModel.loadTaggingBatchRun(runId: runId) {
                sync(with: run)
                if run.status == .review || run.status == .readyNext {
                    try await loadReviewRowsAndStatsIfNeeded()
                } else if run.status == .done || run.status == .cancelled || run.status == .failed {
                    reviewRows = []
                    totalSuggestedTags = 0
                    newTagCount = 0
                    keptProposalCount = run.keptProposalCount
                    discardedProposalCount = run.discardedProposalCount
                    insertedEntryTagCount = run.insertedEntryTagCount
                    createdTagCount = run.createdTagCount
                }
                return
            }

            status = .configure
            processedCount = 0
            succeededCount = 0
            failedCount = 0
            reviewRows = []
            totalSuggestedTags = 0
            newTagCount = 0
            keptProposalCount = 0
            discardedProposalCount = 0
            insertedEntryTagCount = 0
            createdTagCount = 0
            isStopRequested = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sync(with run: TagBatchRun) {
        runId = run.id
        if let scope = TagBatchSelectionScope(rawValue: run.scopeLabel) {
            self.scope = scope
        }
        skipAlreadyApplied = run.skipAlreadyApplied
        skipAlreadyTagged = run.skipAlreadyTagged
        concurrency = run.concurrency
        status = run.status
        processedCount = run.processedEntries
        succeededCount = run.succeededEntries
        failedCount = run.failedEntries
        totalCandidateCount = run.totalPlannedEntries
        keptProposalCount = run.keptProposalCount
        discardedProposalCount = run.discardedProposalCount
        insertedEntryTagCount = run.insertedEntryTagCount
        createdTagCount = run.createdTagCount
        if run.status != .running {
            isStopRequested = false
        }
    }


    private func loadReviewRowsAndStatsIfNeeded() async throws {
        guard let appModel, let runId else {
            reviewRows = []
            totalSuggestedTags = 0
            newTagCount = 0
            return
        }
        reviewRows = try await appModel.loadTaggingBatchReviewRows(runId: runId)
        let stats = try await appModel.loadTaggingBatchSuggestionStats(runId: runId)
        totalSuggestedTags = stats.totalSuggestedTags
        newTagCount = stats.newTagCount
    }
}
