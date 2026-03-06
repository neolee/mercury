import Combine
import Foundation

enum BatchTaggingSheetNotice: Equatable {
    case noEligibleEntries
    case hardSafetyCapExceeded(limit: Int)
    case stopRequested
    case stopBeforeAbort
    case activeRunExists
    case promptTemplateFallback
}

enum BatchTaggingSheetError: Equatable {
    case runNotFound
    case runStillRunning
    case runNotReadyForReview
    case runNotReadyForApply
    case reviewDecisionsPending
    case missingRunID
    case operationFailed(reason: AgentFailureReason)
}

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
    @Published var notice: BatchTaggingSheetNotice?
    @Published var error: BatchTaggingSheetError?
    @Published var completedRunIDForAlert: Int64?

    private weak var appModel: AppModel?
    private var eventTask: Task<Void, Never>?

    deinit {
        eventTask?.cancel()
    }

    var isLifecycleLocked: Bool {
        status.locksConfiguration
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
        await restoreStateFromStore()
        startObservingEvents()
        await refreshCandidateCount()
    }

    func refreshCandidateCount() async {
        guard let appModel else { return }
        do {
            totalCandidateCount = try await appModel.estimateTagBatchEntryCount(
                scope: scope,
                skipAlreadyApplied: skipAlreadyApplied,
                skipAlreadyTagged: skipAlreadyTagged
            )
            error = nil
        } catch {
            totalCandidateCount = 0
            presentError(error)
        }
    }

    func startRun() async {
        guard let appModel else { return }

        isBusy = true
        notice = nil
        error = nil
        defer { isBusy = false }

        do {
            let estimatedCount = try await appModel.estimateTagBatchEntryCount(
                scope: scope,
                skipAlreadyApplied: skipAlreadyApplied,
                skipAlreadyTagged: skipAlreadyTagged
            )
            totalCandidateCount = estimatedCount

            guard estimatedCount > 0 else {
                notice = .noEligibleEntries
                return
            }

            guard estimatedCount <= BatchTaggingPolicy.absoluteSafetyCap else {
                notice = .hardSafetyCapExceeded(limit: BatchTaggingPolicy.absoluteSafetyCap)
                return
            }

            let entryIDs = try await appModel.fetchTagBatchEntryIDsForExecution(
                scope: scope,
                skipAlreadyApplied: skipAlreadyApplied,
                skipAlreadyTagged: skipAlreadyTagged
            )
            guard entryIDs.isEmpty == false else {
                notice = .noEligibleEntries
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
        } catch {
            presentError(error)
        }
    }

    func requestCancelRunning() async {
        guard let appModel, let taskId else { return }
        isStopRequested = true
        await appModel.requestCancelTaggingBatchRun(taskId: taskId)
        notice = .stopRequested
    }

    func continueFromReadyNext() async {
        guard let appModel, let runId else { return }
        if hasReviewRequired {
            do {
                try await appModel.enterTaggingBatchReview(runId: runId)
                await restoreStateFromStore()
            } catch {
                presentError(error)
            }
            return
        }
        await applyDecisions()
    }

    func applyDecisions() async {
        guard let appModel, let runId else { return }

        isBusy = true
        notice = nil
        error = nil
        defer { isBusy = false }

        do {
            try await appModel.applyTaggingBatchRun(runId: runId) { _ in }
        } catch {
            presentError(error)
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
            presentError(error)
        }
    }

    func setAllReviewDecisions(decision: TagBatchReviewDecision) async {
        guard let appModel, let runId else { return }
        do {
            try await appModel.setTaggingBatchReviewDecisionForAll(runId: runId, decision: decision)
            try await loadReviewRowsAndStatsIfNeeded()
        } catch {
            presentError(error)
        }
    }

    func discardRun() async {
        guard let appModel, let runId else { return }

        guard status != .running else {
            notice = .stopBeforeAbort
            return
        }

        isBusy = true
        notice = nil
        error = nil
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
            await restoreStateFromStore()
        } catch {
            presentError(error)
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
        notice = nil
        error = nil
    }

    func resetConfigurationToDefaults() async {
        guard isLifecycleLocked == false else { return }
        scope = .pastWeek
        skipAlreadyApplied = true
        skipAlreadyTagged = true
        concurrency = BatchTaggingPolicy.concurrencyLimit
        isStopRequested = false
        notice = nil
        error = nil
        await refreshCandidateCount()
    }

    private func startObservingEvents() {
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            guard let self, let appModel else { return }
            let stream = await appModel.tagBatchRunEvents()
            for await event in stream {
                if Task.isCancelled { return }
                await self.handle(event: event)
            }
        }
    }

    private func restoreStateFromStore() async {
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
            presentError(error)
        }
    }

    func handle(event: TagBatchRunEvent) async {
        switch event {
        case .started(let taskId, let runId):
            self.taskId = taskId
            self.runId = runId
            isStopRequested = false
            notice = nil
            completedRunIDForAlert = nil
            await restoreRunState(runId: runId)
        case .transitioned(let runId, let status):
            guard shouldHandle(runId: runId) else { return }
            self.runId = runId
            self.status = status
            if status != .running {
                isStopRequested = false
            }
            if status == .done {
                await restoreRunState(runId: runId)
                completedRunIDForAlert = runId
            } else if status == .readyNext || status == .review || status == .cancelled || status == .failed {
                await restoreRunState(runId: runId)
            }
        case .progress(let runId, let processed, let total, let succeeded, let failed):
            guard shouldHandle(runId: runId) else { return }
            self.runId = runId
            processedCount = processed
            totalCandidateCount = total
            succeededCount = succeeded
            failedCount = failed
        case .entryFailed(let runId, _):
            guard shouldHandle(runId: runId) else { return }
            break
        case .notice(let notice):
            presentNotice(notice)
        case .terminal(let outcome):
            switch outcome {
            case .failed, .timedOut:
                error = .operationFailed(reason: outcome.normalizedFailureReason ?? .unknown)
            case .succeeded, .cancelled:
                break
            }
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

    private func shouldHandle(runId: Int64) -> Bool {
        self.runId == nil || self.runId == runId
    }

    private func restoreRunState(runId: Int64) async {
        guard let appModel else { return }
        do {
            guard let run = try await appModel.loadTaggingBatchRun(runId: runId) else {
                return
            }
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
        } catch {
            presentError(error)
        }
    }

    private func presentNotice(_ notice: TagBatchRunNotice) {
        switch notice {
        case .activeRunExists:
            self.notice = .activeRunExists
        case .hardSafetyCapExceeded(let limit):
            self.notice = .hardSafetyCapExceeded(limit: limit)
        case .promptTemplateFallback:
            self.notice = .promptTemplateFallback
        }
    }

    private func presentError(_ error: Error) {
        switch error {
        case TagBatchActionError.runNotFound:
            self.error = .runNotFound
        case TagBatchActionError.runStillRunning:
            self.error = .runStillRunning
        case TagBatchActionError.runNotReadyForReview:
            self.error = .runNotReadyForReview
        case TagBatchActionError.runNotReadyForApply:
            self.error = .runNotReadyForApply
        case TagBatchActionError.reviewDecisionsPending:
            self.error = .reviewDecisionsPending
        case TagBatchStoreError.missingRunID:
            self.error = .missingRunID
        default:
            self.error = .operationFailed(reason: AgentFailureClassifier.classify(error: error, taskKind: .taggingBatch))
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
