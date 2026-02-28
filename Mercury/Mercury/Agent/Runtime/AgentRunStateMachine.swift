import Foundation

nonisolated enum AgentRunStateMachine {
    static func canTransition(from: AgentRunPhase, to: AgentRunPhase) -> Bool {
        if from == to {
            return true
        }

        switch from {
        case .idle:
            return [.waiting, .requesting].contains(to)
        case .waiting:
            return [.requesting, .cancelled].contains(to)
        case .requesting:
            return [.generating, .persisting, .completed, .failed, .cancelled, .timedOut].contains(to)
        case .generating:
            return [.persisting, .completed, .failed, .cancelled, .timedOut].contains(to)
        case .persisting:
            return [.completed, .failed, .cancelled, .timedOut].contains(to)
        case .completed, .failed, .cancelled, .timedOut:
            return false
        }
    }

    static func isTerminal(_ phase: AgentRunPhase) -> Bool {
        [.completed, .failed, .cancelled, .timedOut].contains(phase)
    }
}
