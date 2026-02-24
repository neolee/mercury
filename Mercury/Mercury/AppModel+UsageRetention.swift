import Foundation
import GRDB

enum LLMUsageRetentionPolicy: String, CaseIterable, Codable, Sendable {
    case oneMonth
    case threeMonths
    case sixMonths
    case oneYear
    case forever

    static let defaultValue: Self = .sixMonths

    var retentionMonths: Int? {
        switch self {
        case .oneMonth:
            return 1
        case .threeMonths:
            return 3
        case .sixMonths:
            return 6
        case .oneYear:
            return 12
        case .forever:
            return nil
        }
    }

    func cutoffDate(referenceDate: Date, calendar: Calendar = .current) -> Date? {
        guard let retentionMonths else {
            return nil
        }
        return calendar.date(byAdding: .month, value: -retentionMonths, to: referenceDate)
    }
}

extension AppModel {
    private var llmUsageRetentionPolicyKey: String {
        "Agent.Usage.RetentionPolicy"
    }

    func loadLLMUsageRetentionPolicy() -> LLMUsageRetentionPolicy {
        let defaults = UserDefaults.standard
        guard
            let raw = defaults.string(forKey: llmUsageRetentionPolicyKey),
            let policy = LLMUsageRetentionPolicy(rawValue: raw)
        else {
            return .defaultValue
        }
        return policy
    }

    func saveLLMUsageRetentionPolicy(_ policy: LLMUsageRetentionPolicy) {
        UserDefaults.standard.set(policy.rawValue, forKey: llmUsageRetentionPolicyKey)
    }

    @discardableResult
    func clearLLMUsageEvents() async throws -> Int {
        try await database.write { db in
            try LLMUsageEvent.deleteAll(db)
        }
    }

    @discardableResult
    func purgeExpiredLLMUsageEvents(
        policy: LLMUsageRetentionPolicy? = nil,
        referenceDate: Date = Date()
    ) async throws -> Int {
        let policy = policy ?? loadLLMUsageRetentionPolicy()
        guard let cutoffDate = policy.cutoffDate(referenceDate: referenceDate) else {
            return 0
        }

        return try await database.write { db in
            try LLMUsageEvent
                .filter(Column("createdAt") < cutoffDate)
                .deleteAll(db)
        }
    }

    @discardableResult
    func runStartupLLMUsageRetentionCleanupIfReady(
        policy: LLMUsageRetentionPolicy? = nil,
        referenceDate: Date = Date()
    ) async -> Int {
        guard startupGateState == .ready else {
            return 0
        }

        do {
            return try await purgeExpiredLLMUsageEvents(
                policy: policy,
                referenceDate: referenceDate
            )
        } catch {
            reportDebugIssue(
                title: "LLM Usage Retention Cleanup Failed",
                detail: [
                    "source=startup",
                    "error=\(error.localizedDescription)"
                ].joined(separator: "\n"),
                category: .task
            )
            return 0
        }
    }
}
