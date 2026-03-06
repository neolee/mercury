import Foundation

nonisolated enum AgentMessageHost: String, Equatable, Sendable {
    case readerTopBanner
    case batchSheetFooterMessageArea
    case inlinePanelStatus
    case modalAlert
}

nonisolated enum AgentMessageSeverity: String, Equatable, Sendable {
    case info
    case success
    case warning
    case error
}

nonisolated enum AgentProjectedMessageActionID: String, Equatable, Sendable {
    case openSettings
    case openDebugIssues
}

nonisolated struct AgentProjectedMessageAction: Equatable, Sendable {
    let id: AgentProjectedMessageActionID
    let label: String
}

nonisolated struct AgentProjectedMessage: Equatable, Sendable {
    let primaryText: String
    let secondaryText: String?
    let severity: AgentMessageSeverity
    let primaryAction: AgentProjectedMessageAction?
    let secondaryAction: AgentProjectedMessageAction?
    let host: AgentMessageHost

    var hasActions: Bool {
        primaryAction != nil || secondaryAction != nil
    }
}

nonisolated struct AgentHostRenderedMessageModel: Equatable, Sendable {
    let primaryText: String
    let secondaryText: String?
    let severity: AgentMessageSeverity
    let primaryActionLabel: String?
    let secondaryActionLabel: String?

    var hasActions: Bool {
        primaryActionLabel != nil || secondaryActionLabel != nil
    }
}

nonisolated enum AgentMessageHostAdapter {
    static func readerBannerModel(from message: ReaderBannerMessage?) -> AgentHostRenderedMessageModel? {
        guard let message else {
            return nil
        }

        return makeModel(
            primaryText: message.text,
            secondaryText: nil,
            severity: message.severity,
            primaryActionLabel: message.action?.label,
            secondaryActionLabel: message.secondaryAction?.label
        )
    }

    static func readerBannerModel(from message: AgentProjectedMessage?) -> AgentHostRenderedMessageModel? {
        guard let message, message.host == .readerTopBanner else {
            return nil
        }

        return makeModel(
            primaryText: message.primaryText,
            secondaryText: message.secondaryText,
            severity: message.severity,
            primaryActionLabel: message.primaryAction?.label,
            secondaryActionLabel: message.secondaryAction?.label
        )
    }

    static func batchSheetFooterModel(from message: AgentProjectedMessage?) -> AgentHostRenderedMessageModel? {
        guard let message, message.host == .batchSheetFooterMessageArea else {
            return nil
        }

        return makeModel(
            primaryText: message.primaryText,
            secondaryText: message.secondaryText,
            severity: message.severity,
            primaryActionLabel: message.primaryAction?.label,
            secondaryActionLabel: message.secondaryAction?.label
        )
    }

    private static func makeModel(
        primaryText: String,
        secondaryText: String?,
        severity: AgentMessageSeverity,
        primaryActionLabel: String?,
        secondaryActionLabel: String?
    ) -> AgentHostRenderedMessageModel? {
        let normalizedPrimary = normalize(primaryText)
        let normalizedSecondary = normalize(secondaryText)

        guard let normalizedPrimary else {
            return nil
        }

        return AgentHostRenderedMessageModel(
            primaryText: normalizedPrimary,
            secondaryText: normalizedSecondary,
            severity: severity,
            primaryActionLabel: normalize(primaryActionLabel),
            secondaryActionLabel: normalize(secondaryActionLabel)
        )
    }

    private static func normalize(_ text: String?) -> String? {
        guard let text else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated struct AgentTaskPresentationPolicy: Equatable, Sendable {
    let taskKind: AgentTaskKind
    let primaryMessageHost: AgentMessageHost
    let allowsInlineNoticeDuringRun: Bool
    let allowsTerminalMessage: Bool
    let allowsActionLinks: Bool
}

nonisolated struct AgentProjectedMessageCandidate: Equatable, Sendable {
    let owner: AgentRunOwner
    let requestSource: AgentTaskRequestSource
    let createdAt: Date
    let message: AgentProjectedMessage
}

nonisolated enum AgentMessagePresentation {
    static func policy(for taskKind: AgentTaskKind) -> AgentTaskPresentationPolicy {
        switch taskKind {
        case .summary, .translation, .tagging:
            return AgentTaskPresentationPolicy(
                taskKind: taskKind,
                primaryMessageHost: .readerTopBanner,
                allowsInlineNoticeDuringRun: false,
                allowsTerminalMessage: true,
                allowsActionLinks: true
            )
        case .taggingBatch:
            return AgentTaskPresentationPolicy(
                taskKind: taskKind,
                primaryMessageHost: .batchSheetFooterMessageArea,
                allowsInlineNoticeDuringRun: true,
                allowsTerminalMessage: true,
                allowsActionLinks: true
            )
        }
    }

    static func arbitrateReaderBanner(
        current: AgentProjectedMessageCandidate?,
        incoming: AgentProjectedMessageCandidate?,
        displayedEntryId: Int64?
    ) -> AgentProjectedMessageCandidate? {
        guard let displayedEntryId else {
            return nil
        }

        let eligibleCurrent = current.flatMap {
            isEligibleReaderBannerCandidate($0, displayedEntryId: displayedEntryId) ? $0 : nil
        }
        let eligibleIncoming = incoming.flatMap {
            isEligibleReaderBannerCandidate($0, displayedEntryId: displayedEntryId) ? $0 : nil
        }

        switch (eligibleCurrent, eligibleIncoming) {
        case (nil, nil):
            return nil
        case let (current?, nil):
            return current
        case let (nil, incoming?):
            return incoming
        case let (current?, incoming?):
            return preferredReaderBannerCandidate(current: current, incoming: incoming)
        }
    }

    private static func isEligibleReaderBannerCandidate(
        _ candidate: AgentProjectedMessageCandidate,
        displayedEntryId: Int64
    ) -> Bool {
        candidate.message.host == .readerTopBanner && candidate.owner.entryId == displayedEntryId
    }

    private static func preferredReaderBannerCandidate(
        current: AgentProjectedMessageCandidate,
        incoming: AgentProjectedMessageCandidate
    ) -> AgentProjectedMessageCandidate {
        let currentRank = priorityRank(for: current)
        let incomingRank = priorityRank(for: incoming)

        if incomingRank != currentRank {
            return incomingRank > currentRank ? incoming : current
        }

        return incoming.createdAt >= current.createdAt ? incoming : current
    }

    private static func priorityRank(for candidate: AgentProjectedMessageCandidate) -> Int {
        let manualBoost = candidate.requestSource == .manual ? 2 : 0
        let actionBoost = candidate.message.hasActions ? 1 : 0
        return manualBoost + actionBoost
    }
}

nonisolated struct AgentRuntimeDisplayStrings: Equatable, Sendable {
    let noContent: String
    let loading: String
    let waiting: String
    let requesting: String
    let generating: String
    let persisting: String
    let fetchFailedRetry: String
}

nonisolated struct AgentRuntimeProjectionInput: Equatable, Sendable {
    let hasContent: Bool
    let isLoading: Bool
    let hasFetchFailure: Bool
    let hasPendingRequest: Bool
    let activePhase: AgentRunPhase?
}

nonisolated struct AgentRuntimeStatusProjection: Equatable, Sendable {
    let phase: AgentRunPhase
    let statusText: String?
    let isWaiting: Bool
    let shouldRenderNoContentStatus: Bool
}

nonisolated enum AgentRuntimeProjection {
    @MainActor static func summaryNoContentStatus() -> String {
        String(localized: "No summary", bundle: LanguageManager.shared.bundle)
    }

    @MainActor static func summaryCancelledStatus() -> String {
        String(localized: "Cancelled.", bundle: LanguageManager.shared.bundle)
    }

    @MainActor static func summaryDisplayStrings() -> AgentRuntimeDisplayStrings {
        let b = LanguageManager.shared.bundle
        let p = phaseDisplayStrings()
        return AgentRuntimeDisplayStrings(
            noContent: summaryNoContentStatus(),
            loading: NSLocalizedString("Loading...", bundle: b, comment: ""),
            waiting: p.waiting,
            requesting: p.requesting,
            generating: p.generating,
            persisting: p.persisting,
            fetchFailedRetry: summaryNoContentStatus()
        )
    }

    @MainActor static func translationNoContentStatus() -> String {
        NSLocalizedString("No translation", bundle: LanguageManager.shared.bundle, comment: "")
    }

    @MainActor static func fetchDataFailedStatus() -> String {
        NSLocalizedString("Fetch data failed.", bundle: LanguageManager.shared.bundle, comment: "")
    }

    @MainActor static func translationFetchFailedRetryStatus() -> String {
        fetchDataFailedStatus()
    }

    @MainActor static func translationRateLimitStatus() -> String {
        String(
            localized: "Rate limit reached. Reduce translation concurrency, switch model/provider tier, then retry later.",
            bundle: LanguageManager.shared.bundle
        )
    }

    @MainActor static func summaryNoticeMessage(_ notice: SummaryRunNotice) -> String {
        switch notice {
        case .promptTemplateFallback:
            return AgentPromptCustomizationConfig.summary.invalidTemplateFallbackMessage(
                bundle: LanguageManager.shared.bundle
            )
        }
    }

    @MainActor static func translationNoticeMessage(_ notice: TranslationRunNotice) -> String {
        switch notice {
        case .promptTemplateFallback:
            return AgentPromptCustomizationConfig.translation.invalidTemplateFallbackMessage(
                bundle: LanguageManager.shared.bundle
            )
        }
    }

    @MainActor static func taggingNoticeMessage(_ notice: TaggingPanelNotice) -> String {
        switch notice {
        case .promptTemplateFallback:
            return AgentPromptCustomizationConfig.tagging.invalidTemplateFallbackMessage(
                bundle: LanguageManager.shared.bundle
            )
        }
    }

    @MainActor static func availabilityMessage(
        for taskKind: AgentTaskKind,
        summaryAvailable: Bool,
        translationAvailable: Bool,
        taggingAvailable: Bool
    ) -> String {
        let bundle = LanguageManager.shared.bundle
        let hasAnyConfiguredAgent = summaryAvailable || translationAvailable || taggingAvailable
        guard hasAnyConfiguredAgent else {
            return String(
                localized: "Agents are not configured. Add a provider and model in Settings.",
                bundle: bundle
            )
        }

        switch taskKind {
        case .summary:
            return String(
                localized: "Summary agent is not configured. Add a provider and model in Settings to enable summaries.",
                bundle: bundle
            )
        case .translation:
            return String(
                localized: "Translation agent is not configured. Add a provider and model in Settings to enable translation.",
                bundle: bundle
            )
        case .tagging, .taggingBatch:
            return String(
                localized: "Tagging agent is not configured. Add a provider and model in Settings to enable tagging.",
                bundle: bundle
            )
        default:
            return String(
                localized: "Agent is not configured. Add a provider and model in Settings.",
                bundle: bundle
            )
        }
    }

    @MainActor static func taggingUpdateFailedMessage() -> String {
        String(localized: "Tag update failed", bundle: LanguageManager.shared.bundle)
    }

    @MainActor static func translationWaitingStatus() -> String {
        phaseDisplayStrings().waiting
    }

    @MainActor static func summaryPlaceholderText(
        hasContent: Bool,
        isLoading: Bool,
        hasFetchFailure: Bool,
        hasPendingRequest: Bool,
        activePhase: AgentRunPhase?
    ) -> String {
        placeholderText(
            input: AgentRuntimeProjectionInput(
                hasContent: hasContent,
                isLoading: isLoading,
                hasFetchFailure: hasFetchFailure,
                hasPendingRequest: hasPendingRequest,
                activePhase: activePhase
            ),
            strings: summaryDisplayStrings()
        )
    }

    @MainActor static func translationDisplayStrings(
        noContentStatus: String,
        fetchFailedRetryStatus: String
    ) -> AgentRuntimeDisplayStrings {
        let p = phaseDisplayStrings()
        return AgentRuntimeDisplayStrings(
            noContent: noContentStatus,
            loading: p.generating,
            waiting: p.waiting,
            requesting: p.requesting,
            generating: p.generating,
            persisting: p.persisting,
            fetchFailedRetry: fetchFailedRetryStatus
        )
    }

    @MainActor static func translationStatusText(for phase: AgentRunPhase) -> String {
        let p = phaseDisplayStrings()
        switch phase {
        case .waiting:    return p.waiting
        case .requesting: return p.requesting
        case .generating: return p.generating
        case .persisting: return p.persisting
        case .completed, .failed, .cancelled, .timedOut, .idle:
            return translationNoContentStatus()
        }
    }

    @MainActor private static func phaseDisplayStrings() -> (waiting: String, requesting: String, generating: String, persisting: String) {
        let b = LanguageManager.shared.bundle
        return (
            waiting: NSLocalizedString("Waiting for last generation to finish...", bundle: b, comment: ""),
            requesting: NSLocalizedString("Requesting...", bundle: b, comment: ""),
            generating: NSLocalizedString("Generating...", bundle: b, comment: ""),
            persisting: NSLocalizedString("Persisting...", bundle: b, comment: "")
        )
    }

    static func statusProjection(state: AgentRunState) -> AgentRuntimeStatusProjection {
        let normalizedStatus = state.statusText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let statusText = (normalizedStatus?.isEmpty == false) ? normalizedStatus : nil
        let phase = state.phase
        return AgentRuntimeStatusProjection(
            phase: phase,
            statusText: statusText,
            isWaiting: phase == .waiting,
            shouldRenderNoContentStatus: phase == .failed ||
                phase == .timedOut ||
                phase == .completed ||
                phase == .cancelled
        )
    }

    static func placeholderText(
        input: AgentRuntimeProjectionInput,
        strings: AgentRuntimeDisplayStrings
    ) -> String {
        if input.hasContent {
            return ""
        }
        if input.hasFetchFailure {
            return strings.fetchFailedRetry
        }
        if input.isLoading {
            return strings.loading
        }
        if input.hasPendingRequest {
            return strings.waiting
        }

        switch input.activePhase {
        case .requesting:
            return strings.requesting
        case .generating:
            return strings.generating
        case .persisting:
            return strings.persisting
        default:
            return strings.noContent
        }
    }

    static func missingContentStatusText(
        projection: AgentRuntimeStatusProjection?,
        cachedStatus: String?,
        transientStatuses: Set<String>,
        noContentStatus: String,
        strings: AgentRuntimeDisplayStrings
    ) -> String {
        if let projection {
            if let status = projection.statusText {
                return status
            }
            if projection.shouldRenderNoContentStatus {
                return noContentStatus
            }
            return placeholderText(
                input: AgentRuntimeProjectionInput(
                    hasContent: false,
                    isLoading: false,
                    hasFetchFailure: false,
                    hasPendingRequest: projection.isWaiting,
                    activePhase: projection.phase
                ),
                strings: strings
            )
        }

        if let cachedStatus,
           transientStatuses.contains(cachedStatus) {
            return noContentStatus
        }
        return cachedStatus ?? noContentStatus
    }

    @MainActor static func translationMissingStatusText(
        projection: AgentRuntimeStatusProjection?,
        cachedPhase: AgentRunPhase?,
        noContentStatus: String,
        fetchFailedRetryStatus: String
    ) -> String {
        missingContentStatusText(
            projection: projection,
            cachedStatus: nil,
            transientStatuses: [],
            noContentStatus: noContentStatus,
            strings: translationDisplayStrings(
                noContentStatus: noContentStatus,
                fetchFailedRetryStatus: fetchFailedRetryStatus
            )
        )
    }

    @MainActor static func failureMessage(for reason: AgentFailureReason, taskKind: AgentTaskKind) -> String {
        let b = LanguageManager.shared.bundle
        switch reason {
        case .timedOut:
            return String(localized: "Request timed out.", bundle: b)
        case .network:
            return String(localized: "Network error.", bundle: b)
        case .authentication:
            return String(localized: "Authentication failed. Check agent settings.", bundle: b)
        case .noModelRoute:
            return String(localized: "No model route. Check agent settings.", bundle: b)
        case .invalidConfiguration:
            return String(localized: "Invalid agent configuration. Check settings.", bundle: b)
        case .parser:
            return String(localized: "Model response format invalid.", bundle: b)
        case .storage:
            return String(localized: "Failed to save result. Check Debug Issues.", bundle: b)
        case .invalidInput:
            switch taskKind {
            case .summary:
                return String(localized: "No summary source available.", bundle: b)
            case .translation:
                return String(localized: "No translation source segments available.", bundle: b)
            case .tagging, .taggingBatch:
                return String(localized: "No tagging source available.", bundle: b)
            }
        case .cancelled:
            return String(localized: "Cancelled.", bundle: b)
        case .unknown:
            return String(localized: "Failed. Check Debug Issues.", bundle: b)
        }
    }

    @MainActor static func bannerMessage(
        for outcome: TaskTerminalOutcome,
        taskKind: AgentTaskKind
    ) -> String? {
        switch outcome {
        case .failed, .timedOut:
            if taskKind == .translation,
               let message = outcome.message,
               isRateLimitMessage(message) {
                return translationRateLimitStatus()
            }
            let reason = outcome.normalizedFailureReason ?? .unknown
            return failureMessage(for: reason, taskKind: taskKind)
        case .succeeded, .cancelled:
            return nil
        }
    }

    @MainActor static func terminalBannerMessage(
        for outcome: TaskTerminalOutcome,
        taskKind: AgentTaskKind,
        noticeText: String? = nil
    ) -> String? {
        guard case .failed = outcome else {
            if case .timedOut = outcome {
                let failureText = bannerMessage(for: outcome, taskKind: taskKind)
                    ?? failureMessage(for: outcome.normalizedFailureReason ?? .unknown, taskKind: taskKind)
                if let noticeText = normalizeMessageText(noticeText) {
                    return "\(noticeText) \(failureText)"
                }
                return failureText
            }
            return nil
        }

        let failureText = bannerMessage(for: outcome, taskKind: taskKind)
            ?? failureMessage(for: outcome.normalizedFailureReason ?? .unknown, taskKind: taskKind)
        if let noticeText = normalizeMessageText(noticeText) {
            return "\(noticeText) \(failureText)"
        }
        return failureText
    }

    private static func normalizeMessageText(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
