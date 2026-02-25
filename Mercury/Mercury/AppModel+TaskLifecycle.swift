import Foundation

struct AgentRuntimeSubmitResult: Sendable {
    let decision: AgentRunRequestDecision
    let activeToken: String?
}

extension AppModel {
    func submitAgentTask(
        taskId: UnifiedTaskID,
        kind: UnifiedTaskKind,
        owner: AgentTaskOwner,
        requestSource: AgentTaskRequestSource,
        visibilityPolicy: AgentVisibilityPolicy = .selectedEntryOnly
    ) async -> AgentRuntimeSubmitResult {
        let route = UnifiedTaskExecutionRouter.route(for: kind)
        guard case .queueAndRuntime(_, let expectedAgentKind) = route else {
            assertionFailure("Queue-only task kind cannot be submitted to agent runtime: \(kind.rawValue)")
            return AgentRuntimeSubmitResult(decision: .alreadyActive, activeToken: nil)
        }
        guard owner.taskKind == expectedAgentKind else {
            assertionFailure(
                "Agent task kind mismatch for runtime submit. kind=\(kind.rawValue) expected=\(expectedAgentKind.rawValue) actual=\(owner.taskKind.rawValue)"
            )
            return AgentRuntimeSubmitResult(decision: .alreadyActive, activeToken: nil)
        }

        let decision = await agentRuntimeEngine.submit(
            spec: AgentTaskSpec(
                taskId: taskId,
                owner: owner,
                requestSource: requestSource,
                visibilityPolicy: visibilityPolicy
            )
        )
        let activeToken: String?
        if case .startNow = decision {
            activeToken = await agentRuntimeEngine.activeToken(for: owner)
        } else {
            activeToken = nil
        }
        return AgentRuntimeSubmitResult(decision: decision, activeToken: activeToken)
    }
}
