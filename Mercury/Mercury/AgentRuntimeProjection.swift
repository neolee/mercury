import Foundation

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
    static func summaryNoContentStatus() -> String {
        "No summary"
    }

    static func summaryCancelledStatus() -> String {
        "Cancelled."
    }

    static func summaryDisplayStrings() -> AgentRuntimeDisplayStrings {
        AgentRuntimeDisplayStrings(
            noContent: summaryNoContentStatus(),
            loading: "Loading...",
            waiting: "Waiting for last generation to finish...",
            requesting: "Requesting...",
            generating: "Generating...",
            persisting: "Persisting...",
            fetchFailedRetry: summaryNoContentStatus()
        )
    }

    static func translationNoContentStatus() -> String {
        TranslationGlobalStatusText.noTranslationYet
    }

    static func translationFetchFailedRetryStatus() -> String {
        TranslationGlobalStatusText.fetchFailedRetry
    }

    static func translationWaitingStatus() -> String {
        TranslationSegmentStatusText.waitingForPreviousRun.rawValue
    }

    static func translationTransientStatuses() -> Set<String> {
        [
            translationWaitingStatus(),
            TranslationSegmentStatusText.requesting.rawValue,
            TranslationSegmentStatusText.generating.rawValue,
            TranslationSegmentStatusText.persisting.rawValue
        ]
    }

    static func isTranslationWaitingStatus(_ status: String) -> Bool {
        status == translationWaitingStatus()
    }

    static func summaryPlaceholderText(
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

    static func translationDisplayStrings(
        noContentStatus: String,
        fetchFailedRetryStatus: String
    ) -> AgentRuntimeDisplayStrings {
        AgentRuntimeDisplayStrings(
            noContent: noContentStatus,
            loading: TranslationSegmentStatusText.generating.rawValue,
            waiting: translationWaitingStatus(),
            requesting: TranslationSegmentStatusText.requesting.rawValue,
            generating: TranslationSegmentStatusText.generating.rawValue,
            persisting: TranslationSegmentStatusText.persisting.rawValue,
            fetchFailedRetry: fetchFailedRetryStatus
        )
    }

    static func translationStatusText(for phase: AgentRunPhase) -> String {
        let strings = translationDisplayStrings(
            noContentStatus: translationNoContentStatus(),
            fetchFailedRetryStatus: translationFetchFailedRetryStatus()
        )
        switch phase {
        case .waiting:
            return strings.waiting
        case .requesting:
            return strings.requesting
        case .generating:
            return strings.generating
        case .persisting:
            return strings.persisting
        case .completed, .failed, .cancelled, .timedOut, .idle:
            return strings.noContent
        }
    }

    static func translationStatusTextForAlreadyActive(cachedStatus: String?) -> String {
        cachedStatus ?? translationStatusText(for: .generating)
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

    static func translationMissingStatusText(
        projection: AgentRuntimeStatusProjection?,
        cachedStatus: String?,
        transientStatuses: Set<String>,
        noContentStatus: String,
        fetchFailedRetryStatus: String
    ) -> String {
        missingContentStatusText(
            projection: projection,
            cachedStatus: cachedStatus,
            transientStatuses: transientStatuses,
            noContentStatus: noContentStatus,
            strings: translationDisplayStrings(
                noContentStatus: noContentStatus,
                fetchFailedRetryStatus: fetchFailedRetryStatus
            )
        )
    }

    static func failureMessage(for reason: AgentFailureReason, taskKind: AgentTaskKind) -> String {
        switch reason {
        case .timedOut:
            return "Request timed out."
        case .network:
            return "Network error."
        case .authentication:
            return "Authentication failed. Check agent settings."
        case .noModelRoute:
            return "No model route. Check agent settings."
        case .invalidConfiguration:
            return "Invalid agent configuration. Check settings."
        case .parser:
            return "Model response format invalid."
        case .storage:
            return "Failed to save result. Check Debug Issues."
        case .invalidInput:
            return taskKind == .summary
                ? "No summary source available."
                : "No translation source segments available."
        case .cancelled:
            return "Cancelled."
        case .unknown:
            return "Failed. Check Debug Issues."
        }
    }
}
