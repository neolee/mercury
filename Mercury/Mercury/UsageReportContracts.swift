import Foundation

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
