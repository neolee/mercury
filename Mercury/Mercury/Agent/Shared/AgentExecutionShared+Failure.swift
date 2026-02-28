import Foundation

nonisolated enum AgentCancellationOutcome: Sendable {
    case timedOut(error: AppTaskTimeoutError, failureReason: AgentFailureReason)
    case userCancelled(failureReason: AgentFailureReason)
}

private func timeoutKindForProviderKind(_ kind: LLMProviderError.TimeoutKind) -> TaskTimeoutKind {
    switch kind {
    case .request:
        return .request
    case .resource:
        return .resource
    case .streamFirstToken:
        return .streamFirstToken
    case .streamIdle:
        return .streamIdle
    }
}

private func isTimeoutMessage(_ message: String) -> Bool {
    let message = message.lowercased()
    return message.contains("timed out") || message.contains("timeout")
}

func timeoutKindForError(_ error: Error) -> TaskTimeoutKind? {
    if let providerError = error as? LLMProviderError {
        switch providerError {
        case .timedOut(let kind, _):
            return timeoutKindForProviderKind(kind)
        case .network(let message), .unknown(let message):
            return isTimeoutMessage(message) ? .unknown : nil
        case .invalidConfiguration, .unauthorized, .cancelled:
            return nil
        }
    }

    if error is AppTaskTimeoutError {
        return .execution
    }

    if let urlError = error as? URLError, urlError.code == .timedOut {
        return .request
    }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain && nsError.code == URLError.timedOut.rawValue {
        return .request
    }
    if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ETIMEDOUT) {
        return .request
    }
    return nil
}

func terminalOutcomeForCancellation(
    taskKind: AgentTaskKind,
    terminationReason: AppTaskTerminationReason?
) -> TaskTerminalOutcome {
    let cancellationOutcome = resolveAgentCancellationOutcome(
        taskKind: taskKind,
        terminationReason: terminationReason
    )
    switch cancellationOutcome {
    case .timedOut(let timeoutError, let failureReason):
        return .timedOut(
            failureReason: failureReason,
            message: timeoutError.localizedDescription
        )
    case .userCancelled(let failureReason):
        return .cancelled(failureReason: failureReason)
    }
}

func resolveAgentCancellationOutcome(
    taskKind: AgentTaskKind,
    terminationReason: AppTaskTerminationReason?
) -> AgentCancellationOutcome {
    if terminationReason == .timedOut {
        let timeoutError = makeAgentTimeoutError(taskKind: taskKind)
        let failureReason = AgentFailureClassifier.classify(error: timeoutError, taskKind: taskKind)
        return .timedOut(error: timeoutError, failureReason: failureReason)
    }

    // Queue cancellation should always set a reason. If missing, normalize to user-cancelled
    // instead of inferring timeout semantics.
    if terminationReason == nil {
        assertionFailure("Missing task termination reason for cancellation.")
    }
    let failureReason = AgentFailureClassifier.classify(error: CancellationError(), taskKind: taskKind)
    return .userCancelled(failureReason: failureReason)
}

private func makeAgentTimeoutError(taskKind: AgentTaskKind) -> AppTaskTimeoutError {
    let unifiedKind = UnifiedTaskKind.from(agentTaskKind: taskKind)
    let appTaskKind = unifiedKind.appTaskKind
    let timeoutSeconds = Int(TaskTimeoutPolicy.executionTimeout(for: unifiedKind) ?? 0)
    return AppTaskTimeoutError.executionTimedOut(kind: appTaskKind, seconds: timeoutSeconds)
}

func usageStatusForCancellation(
    taskKind: AgentTaskKind,
    terminationReason: AppTaskTerminationReason?
) -> LLMUsageRequestStatus {
    terminalOutcomeForCancellation(taskKind: taskKind, terminationReason: terminationReason).usageStatus
}

func usageStatusForFailure(error: Error, taskKind: AgentTaskKind) -> LLMUsageRequestStatus {
    terminalOutcomeForFailure(error: error, taskKind: taskKind).usageStatus
}

func terminalOutcomeForFailure(error: Error, taskKind: AgentTaskKind) -> TaskTerminalOutcome {
    let failureReason = AgentFailureClassifier.classify(error: error, taskKind: taskKind)
    if failureReason == .timedOut {
        return TaskTerminalOutcome
            .timedOut(failureReason: failureReason, message: error.localizedDescription)
    }
    return TaskTerminalOutcome
        .failed(failureReason: failureReason, message: error.localizedDescription)
}

func isCancellationLikeError(_ error: Error) -> Bool {
    if error is CancellationError {
        return true
    }
    if let providerError = error as? LLMProviderError, case .cancelled = providerError {
        return true
    }
    return false
}

private func containsRateLimitSignal(_ message: String) -> Bool {
    let normalized = message.lowercased()
    if normalized.contains("too many requests") {
        return true
    }
    if normalized.contains("rate limit") || normalized.contains("rate-limit") {
        return true
    }
    if normalized.contains("http 429") || normalized.contains("status code: 429") || normalized.contains("status code 429") {
        return true
    }
    return normalized.contains("429")
}

func isRateLimitMessage(_ message: String) -> Bool {
    containsRateLimitSignal(message)
}

func isRateLimitError(_ error: Error) -> Bool {
    if let providerError = error as? LLMProviderError {
        switch providerError {
        case .network(let message), .unknown(let message):
            if containsRateLimitSignal(message) {
                return true
            }
        case .invalidConfiguration, .timedOut, .unauthorized, .cancelled:
            break
        }
    }

    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == 429 {
        return true
    }
    return containsRateLimitSignal(nsError.localizedDescription)
}
