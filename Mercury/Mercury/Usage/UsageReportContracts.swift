import Foundation
import SwiftUI

enum UsageReportWindowPreset: String, CaseIterable, Codable, Sendable {
    case last1Week
    case last2Weeks
    case last1Month

    var dayCount: Int {
        switch self {
        case .last1Week:
            return 7
        case .last2Weeks:
            return 14
        case .last1Month:
            return 30
        }
    }

    func interval(referenceDate: Date, calendar: Calendar = .current) -> DateInterval {
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: referenceDate))
            ?? referenceDate
        let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: calendar.startOfDay(for: referenceDate))
            ?? referenceDate
        return DateInterval(start: start, end: endExclusive)
    }
}

enum UsageReportObjectScope: Sendable, Hashable {
    case provider(id: Int64)
    case model(id: Int64)
    case agent(taskType: AgentTaskType)
}

enum UsageReportSecondaryFilter: Sendable, Hashable {
    case none
    case taskAggregation(AgentTaskType?)
    case providerSelection(providerId: Int64?)
}

struct UsageReportQuery: Sendable, Hashable {
    let scope: UsageReportObjectScope
    let windowPreset: UsageReportWindowPreset
    let secondaryFilter: UsageReportSecondaryFilter

    init(
        scope: UsageReportObjectScope,
        windowPreset: UsageReportWindowPreset,
        secondaryFilter: UsageReportSecondaryFilter = .none
    ) {
        self.scope = scope
        self.windowPreset = windowPreset
        self.secondaryFilter = secondaryFilter
    }
}

struct ProviderUsageDailyBucket: Identifiable, Sendable {
    var id: Date { dayStart }
    let dayStart: Date
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let succeededCount: Int
    let failedCount: Int
    let missingUsageCount: Int
}

struct ProviderUsageSummaryBlock: Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let succeededCount: Int
    let failedCount: Int
    let missingUsageCount: Int
}

struct ProviderUsageQualityMetrics: Sendable {
    let successRate: Double
    let usageCoverageRate: Double
    let averageTokensPerRequest: Double
}

struct ProviderUsagePeriodDelta: Sendable {
    let currentValue: Double
    let previousValue: Double
    let delta: Double
    let deltaRatio: Double?
}

struct ProviderUsagePeriodComparison: Sendable {
    let totalTokens: ProviderUsagePeriodDelta
    let requestCount: ProviderUsagePeriodDelta
    let successRate: ProviderUsagePeriodDelta
    let usageCoverageRate: ProviderUsagePeriodDelta
}

struct ProviderUsageReportSnapshot: Sendable {
    let providerId: Int64
    let windowPreset: UsageReportWindowPreset
    let interval: DateInterval
    let dailyBuckets: [ProviderUsageDailyBucket]
    let summary: ProviderUsageSummaryBlock
    let quality: ProviderUsageQualityMetrics
    let periodComparison: ProviderUsagePeriodComparison
}

struct UsageComparisonItem: Identifiable, Sendable {
    var id: Int64 { objectId }
    let objectId: Int64
    let objectName: String
    let summary: ProviderUsageSummaryBlock
    let quality: ProviderUsageQualityMetrics
    let periodComparison: ProviderUsagePeriodComparison
}

struct UsageComparisonSnapshot: Sendable {
    let windowPreset: UsageReportWindowPreset
    let interval: DateInterval
    let summary: ProviderUsageSummaryBlock
    let quality: ProviderUsageQualityMetrics
    let items: [UsageComparisonItem]
}

typealias ProviderUsageComparisonItem = UsageComparisonItem
typealias ProviderUsageComparisonSnapshot = UsageComparisonSnapshot

extension UsageReportWindowPreset {
    var labelKey: LocalizedStringKey {
        switch self {
        case .last1Week:
            "Last 1 Week"
        case .last2Weeks:
            "Last 2 Weeks"
        case .last1Month:
            "Last 1 Month"
        }
    }
}

enum UsageReportTaskAggregation: Hashable {
    case all
    case task(AgentTaskType)

    static var options: [UsageReportTaskAggregation] {
        var values: [UsageReportTaskAggregation] = [.all]
        values.append(contentsOf: AgentTaskType.allCases.compactMap { taskType in
            taskType.usageReportAggregation
        })
        return values
    }

    var taskType: AgentTaskType? {
        switch self {
        case .all:
            return nil
        case let .task(taskType):
            return taskType
        }
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .all:
            return "All"
        case let .task(taskType):
            return taskType.usageReportLabelKey
        }
    }

    var rawValueForTaskID: String {
        switch self {
        case .all:
            return "all"
        case let .task(taskType):
            return taskType.rawValue
        }
    }
}

extension AgentTaskType {
    var usageReportAggregation: UsageReportTaskAggregation? {
        switch self {
        case .tagging:
            return nil
        case .summary, .translation:
            return .task(self)
        }
    }

    var usageReportLabelKey: LocalizedStringKey {
        switch self {
        case .tagging:
            return "Tagging"
        case .summary:
            return "Summary"
        case .translation:
            return "Translation"
        }
    }
}
