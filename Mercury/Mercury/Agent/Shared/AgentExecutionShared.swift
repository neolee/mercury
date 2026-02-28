import Foundation
import GRDB

struct AgentRouteCandidate: Sendable {
    let provider: AgentProviderProfile
    let model: AgentModelProfile
    let apiKey: String
}

struct AgentTerminalRunContext: Sendable {
    let providerProfileId: Int64?
    let modelProfileId: Int64?
    let templateId: String?
    let templateVersion: String?
    let runtimeSnapshot: [String: String]
}

enum AgentExecutionSharedError: LocalizedError {
    case missingTaskRunID

    var errorDescription: String? {
        switch self {
        case .missingTaskRunID:
            return "Task run ID is missing after insert."
        }
    }
}

struct LLMUsageEventContext: Sendable {
    let taskRunId: Int64?
    let entryId: Int64?
    let taskType: AgentTaskType
    let providerProfileId: Int64?
    let modelProfileId: Int64?
    let providerBaseURLSnapshot: String
    let providerResolvedURLSnapshot: String?
    let providerResolvedHostSnapshot: String?
    let providerResolvedPathSnapshot: String?
    let providerNameSnapshot: String?
    let modelNameSnapshot: String
    let requestPhase: LLMUsageRequestPhase
    let requestStatus: LLMUsageRequestStatus
    let promptTokens: Int?
    let completionTokens: Int?
    let startedAt: Date?
    let finishedAt: Date?
}

enum AgentExecutionShared {
    static func languageDisplayName(for identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return "English (en)"
        }
        if let localized = Locale.current.localizedString(forIdentifier: trimmed) {
            return "\(localized) (\(trimmed))"
        }
        return trimmed
    }

    static func encodeRuntimeSnapshot(_ snapshot: [String: String]) throws -> String? {
        guard snapshot.isEmpty == false else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        return String(data: data, encoding: .utf8)
    }
}
