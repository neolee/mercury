import Foundation
import GRDB

extension AppModel {
    func fetchProviderUsageReport(
        providerId: Int64,
        windowPreset: UsageReportWindowPreset,
        taskType: AgentTaskType? = nil,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> ProviderUsageReportSnapshot {
        let interval = windowPreset.interval(referenceDate: referenceDate, calendar: calendar)
        let previousInterval = DateInterval(
            start: calendar.date(byAdding: .day, value: -windowPreset.dayCount, to: interval.start) ?? interval.start,
            end: interval.start
        )
        let formatter = Self.usageReportDateFormatter(calendar: calendar)

        let rows = try await fetchProviderUsageDailyRows(
            providerId: providerId,
            interval: interval,
            taskType: taskType
        )
        let previousRows = try await fetchProviderUsageDailyRows(
            providerId: providerId,
            interval: previousInterval,
            taskType: taskType
        )

        let currentSummary = Self.summary(from: rows)
        let previousSummary = Self.summary(from: previousRows)

        let quality = Self.qualityMetrics(from: currentSummary)
        let previousQuality = Self.qualityMetrics(from: previousSummary)

        let periodComparison = ProviderUsagePeriodComparison(
            totalTokens: Self.periodDelta(
                current: Double(currentSummary.totalTokens),
                previous: Double(previousSummary.totalTokens)
            ),
            requestCount: Self.periodDelta(
                current: Double(currentSummary.requestCount),
                previous: Double(previousSummary.requestCount)
            ),
            successRate: Self.periodDelta(
                current: quality.successRate,
                previous: previousQuality.successRate
            ),
            usageCoverageRate: Self.periodDelta(
                current: quality.usageCoverageRate,
                previous: previousQuality.usageCoverageRate
            )
        )

        let rowByDay = Dictionary(uniqueKeysWithValues: rows.map { ($0.day, $0) })
        let dayStarts = Self.usageReportDayStarts(interval: interval, calendar: calendar)

        let dailyBuckets = dayStarts.map { dayStart -> ProviderUsageDailyBucket in
            let key = formatter.string(from: dayStart)
            if let row = rowByDay[key] {
                return ProviderUsageDailyBucket(
                    dayStart: dayStart,
                    promptTokens: row.promptTokens,
                    completionTokens: row.completionTokens,
                    totalTokens: row.totalTokens,
                    requestCount: row.requestCount,
                    succeededCount: row.succeededCount,
                    failedCount: row.failedCount,
                    missingUsageCount: row.missingUsageCount
                )
            }

            return ProviderUsageDailyBucket(
                dayStart: dayStart,
                promptTokens: 0,
                completionTokens: 0,
                totalTokens: 0,
                requestCount: 0,
                succeededCount: 0,
                failedCount: 0,
                missingUsageCount: 0
            )
        }

        return ProviderUsageReportSnapshot(
            providerId: providerId,
            windowPreset: windowPreset,
            interval: interval,
            dailyBuckets: dailyBuckets,
            summary: currentSummary,
            quality: quality,
            periodComparison: periodComparison
        )
    }

    private func fetchProviderUsageDailyRows(
        providerId: Int64,
        interval: DateInterval,
        taskType: AgentTaskType?
    ) async throws -> [ProviderUsageDailyRow] {
        try await database.read { db in
            var sql = """
                SELECT
                    date(createdAt, 'localtime') AS day,
                    COALESCE(SUM(promptTokens), 0) AS promptTokens,
                    COALESCE(SUM(completionTokens), 0) AS completionTokens,
                    COALESCE(SUM(totalTokens), 0) AS totalTokens,
                    COUNT(*) AS requestCount,
                    COALESCE(SUM(CASE WHEN requestStatus = ? THEN 1 ELSE 0 END), 0) AS succeededCount,
                    COALESCE(SUM(CASE WHEN requestStatus IN (?, ?, ?) THEN 1 ELSE 0 END), 0) AS failedCount,
                    COALESCE(SUM(CASE WHEN usageAvailability = ? THEN 1 ELSE 0 END), 0) AS missingUsageCount
                FROM llm_usage_event
                WHERE providerProfileId = ?
                    AND createdAt >= ?
                    AND createdAt < ?
                """
            var arguments: [DatabaseValueConvertible] = [
                LLMUsageRequestStatus.succeeded.rawValue,
                LLMUsageRequestStatus.failed.rawValue,
                LLMUsageRequestStatus.cancelled.rawValue,
                LLMUsageRequestStatus.timedOut.rawValue,
                LLMUsageAvailability.missing.rawValue,
                providerId,
                interval.start,
                interval.end
            ]

            if let taskType {
                sql += "\n    AND taskType = ?"
                arguments.append(taskType.rawValue)
            }

            sql += """

                GROUP BY day
                ORDER BY day ASC
                """

            return try ProviderUsageDailyRow.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(arguments)
            )
        }
    }

    private static func usageReportDayStarts(interval: DateInterval, calendar: Calendar) -> [Date] {
        guard interval.end > interval.start else {
            return []
        }

        var result: [Date] = []
        var current = calendar.startOfDay(for: interval.start)
        let last = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start

        while current <= last {
            result.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else {
                break
            }
            current = next
        }
        return result
    }

    private static func usageReportDateFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func summary(from rows: [ProviderUsageDailyRow]) -> ProviderUsageSummaryBlock {
        ProviderUsageSummaryBlock(
            promptTokens: rows.reduce(0) { $0 + $1.promptTokens },
            completionTokens: rows.reduce(0) { $0 + $1.completionTokens },
            totalTokens: rows.reduce(0) { $0 + $1.totalTokens },
            requestCount: rows.reduce(0) { $0 + $1.requestCount },
            succeededCount: rows.reduce(0) { $0 + $1.succeededCount },
            failedCount: rows.reduce(0) { $0 + $1.failedCount },
            missingUsageCount: rows.reduce(0) { $0 + $1.missingUsageCount }
        )
    }

    private static func qualityMetrics(from summary: ProviderUsageSummaryBlock) -> ProviderUsageQualityMetrics {
        let requestCount = max(summary.requestCount, 0)
        guard requestCount > 0 else {
            return ProviderUsageQualityMetrics(
                successRate: 0,
                usageCoverageRate: 0,
                averageTokensPerRequest: 0
            )
        }

        let successRate = Double(summary.succeededCount) / Double(requestCount)
        let usageCoverageRate = Double(max(summary.requestCount - summary.missingUsageCount, 0)) / Double(requestCount)
        let averageTokensPerRequest = Double(summary.totalTokens) / Double(requestCount)

        return ProviderUsageQualityMetrics(
            successRate: successRate,
            usageCoverageRate: usageCoverageRate,
            averageTokensPerRequest: averageTokensPerRequest
        )
    }

    private static func periodDelta(current: Double, previous: Double) -> ProviderUsagePeriodDelta {
        let delta = current - previous
        let deltaRatio: Double?
        if previous == 0 {
            deltaRatio = nil
        } else {
            deltaRatio = delta / previous
        }

        return ProviderUsagePeriodDelta(
            currentValue: current,
            previousValue: previous,
            delta: delta,
            deltaRatio: deltaRatio
        )
    }
}

private struct ProviderUsageDailyRow: FetchableRecord {
    let day: String
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let succeededCount: Int
    let failedCount: Int
    let missingUsageCount: Int

    init(row: Row) {
        day = row["day"]
        promptTokens = row["promptTokens"]
        completionTokens = row["completionTokens"]
        totalTokens = row["totalTokens"]
        requestCount = row["requestCount"]
        succeededCount = row["succeededCount"]
        failedCount = row["failedCount"]
        missingUsageCount = row["missingUsageCount"]
    }
}
