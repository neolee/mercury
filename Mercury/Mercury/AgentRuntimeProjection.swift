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

    @MainActor static func translationFetchFailedRetryStatus() -> String {
        NSLocalizedString("Fetch data failed.", bundle: LanguageManager.shared.bundle, comment: "")
    }

    @MainActor static func translationRateLimitStatus() -> String {
        String(
            localized: "Rate limit reached. Reduce translation concurrency, switch model/provider tier, then retry later.",
            bundle: LanguageManager.shared.bundle
        )
    }

    @MainActor static func translationInvalidCustomPromptFallbackStatus() -> String {
        String(
            localized: "Custom translation prompt is invalid. Using built-in prompt.",
            bundle: LanguageManager.shared.bundle
        )
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
            return taskKind == .summary
                ? String(localized: "No summary source available.", bundle: b)
                : String(localized: "No translation source segments available.", bundle: b)
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
}
