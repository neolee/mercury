import Foundation

nonisolated enum AgentFailureMessageProjection {
    static func message(for reason: AgentFailureReason, taskKind: AgentTaskKind) -> String {
        switch reason {
        case .timedOut:
            return "Request timed out."
        case .network:
            return "Network error."
        case .authentication:
            return "Authentication failed. Check AI settings."
        case .noModelRoute:
            return "No model route. Check AI settings."
        case .invalidConfiguration:
            return "Invalid AI configuration. Check settings."
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
