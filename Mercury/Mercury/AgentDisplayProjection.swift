import Foundation

struct AgentDisplayStrings: Equatable, Sendable {
    let noContent: String
    let loading: String
    let waiting: String
    let requesting: String
    let generating: String
    let persisting: String
    let fetchFailedRetry: String
}

struct AgentDisplayProjectionInput: Equatable, Sendable {
    let hasContent: Bool
    let isLoading: Bool
    let hasFetchFailure: Bool
    let hasPendingRequest: Bool
    let activePhase: AgentRunPhase?
}

enum AgentDisplayProjection {
    static func placeholderText(
        input: AgentDisplayProjectionInput,
        strings: AgentDisplayStrings
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
}
