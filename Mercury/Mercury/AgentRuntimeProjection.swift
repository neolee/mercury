import Foundation

struct AgentRuntimeDisplayStrings: Equatable, Sendable {
    let noContent: String
    let loading: String
    let waiting: String
    let requesting: String
    let generating: String
    let persisting: String
    let fetchFailedRetry: String
}

struct AgentRuntimeProjectionInput: Equatable, Sendable {
    let hasContent: Bool
    let isLoading: Bool
    let hasFetchFailure: Bool
    let hasPendingRequest: Bool
    let activePhase: AgentRunPhase?
}

nonisolated enum AgentRuntimeProjection {
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
