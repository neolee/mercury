import Foundation
import GRDB

extension AppModel {
    func fetchProviderUsageComparisonReport(
        windowPreset: UsageReportWindowPreset,
        taskType: AgentTaskType? = nil,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> ProviderUsageComparisonSnapshot {
        let interval = windowPreset.interval(referenceDate: referenceDate, calendar: calendar)
        let previousInterval = DateInterval(
            start: calendar.date(byAdding: .day, value: -windowPreset.dayCount, to: interval.start) ?? interval.start,
            end: interval.start
        )

        let currentRows = try await fetchProviderUsageComparisonRows(
            interval: interval,
            taskType: taskType
        )
        let previousRows = try await fetchProviderUsageComparisonRows(
            interval: previousInterval,
            taskType: taskType
        )

        let previousByProvider = Dictionary(uniqueKeysWithValues: previousRows.map { ($0.providerId, $0) })

        let items = currentRows
            .map { row -> ProviderUsageComparisonItem in
                let summary = ProviderUsageSummaryBlock(
                    promptTokens: row.promptTokens,
                    completionTokens: row.completionTokens,
                    totalTokens: row.totalTokens,
                    requestCount: row.requestCount,
                    succeededCount: row.succeededCount,
                    failedCount: row.failedCount,
                    missingUsageCount: row.missingUsageCount
                )
                let quality = Self.qualityMetrics(from: summary)

                let previous = previousByProvider[row.providerId]
                let previousSummary = ProviderUsageSummaryBlock(
                    promptTokens: previous?.promptTokens ?? 0,
                    completionTokens: previous?.completionTokens ?? 0,
                    totalTokens: previous?.totalTokens ?? 0,
                    requestCount: previous?.requestCount ?? 0,
                    succeededCount: previous?.succeededCount ?? 0,
                    failedCount: previous?.failedCount ?? 0,
                    missingUsageCount: previous?.missingUsageCount ?? 0
                )
                let previousQuality = Self.qualityMetrics(from: previousSummary)

                let periodComparison = ProviderUsagePeriodComparison(
                    totalTokens: Self.periodDelta(
                        current: Double(summary.totalTokens),
                        previous: Double(previousSummary.totalTokens)
                    ),
                    requestCount: Self.periodDelta(
                        current: Double(summary.requestCount),
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

                return ProviderUsageComparisonItem(
                    objectId: row.providerId,
                    objectName: row.providerName,
                    summary: summary,
                    quality: quality,
                    periodComparison: periodComparison
                )
            }
            .sorted { lhs, rhs in
                if lhs.summary.totalTokens != rhs.summary.totalTokens {
                    return lhs.summary.totalTokens > rhs.summary.totalTokens
                }
                return lhs.objectName.localizedCaseInsensitiveCompare(rhs.objectName) == .orderedAscending
            }

        let totalSummary = ProviderUsageSummaryBlock(
            promptTokens: items.reduce(0) { $0 + $1.summary.promptTokens },
            completionTokens: items.reduce(0) { $0 + $1.summary.completionTokens },
            totalTokens: items.reduce(0) { $0 + $1.summary.totalTokens },
            requestCount: items.reduce(0) { $0 + $1.summary.requestCount },
            succeededCount: items.reduce(0) { $0 + $1.summary.succeededCount },
            failedCount: items.reduce(0) { $0 + $1.summary.failedCount },
            missingUsageCount: items.reduce(0) { $0 + $1.summary.missingUsageCount }
        )

        return ProviderUsageComparisonSnapshot(
            windowPreset: windowPreset,
            interval: interval,
            summary: totalSummary,
            quality: Self.qualityMetrics(from: totalSummary),
            items: items
        )
    }

    func fetchModelUsageComparisonReport(
        windowPreset: UsageReportWindowPreset,
        taskType: AgentTaskType? = nil,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> UsageComparisonSnapshot {
        let interval = windowPreset.interval(referenceDate: referenceDate, calendar: calendar)
        let previousInterval = DateInterval(
            start: calendar.date(byAdding: .day, value: -windowPreset.dayCount, to: interval.start) ?? interval.start,
            end: interval.start
        )

        let currentRows = try await fetchModelUsageComparisonRows(
            interval: interval,
            taskType: taskType
        )
        let previousRows = try await fetchModelUsageComparisonRows(
            interval: previousInterval,
            taskType: taskType
        )

        let previousByModel = Dictionary(uniqueKeysWithValues: previousRows.map { ($0.modelId, $0) })

        let items = currentRows
            .map { row -> UsageComparisonItem in
                let summary = ProviderUsageSummaryBlock(
                    promptTokens: row.promptTokens,
                    completionTokens: row.completionTokens,
                    totalTokens: row.totalTokens,
                    requestCount: row.requestCount,
                    succeededCount: row.succeededCount,
                    failedCount: row.failedCount,
                    missingUsageCount: row.missingUsageCount
                )
                let quality = Self.qualityMetrics(from: summary)

                let previous = previousByModel[row.modelId]
                let previousSummary = ProviderUsageSummaryBlock(
                    promptTokens: previous?.promptTokens ?? 0,
                    completionTokens: previous?.completionTokens ?? 0,
                    totalTokens: previous?.totalTokens ?? 0,
                    requestCount: previous?.requestCount ?? 0,
                    succeededCount: previous?.succeededCount ?? 0,
                    failedCount: previous?.failedCount ?? 0,
                    missingUsageCount: previous?.missingUsageCount ?? 0
                )
                let previousQuality = Self.qualityMetrics(from: previousSummary)

                let periodComparison = ProviderUsagePeriodComparison(
                    totalTokens: Self.periodDelta(
                        current: Double(summary.totalTokens),
                        previous: Double(previousSummary.totalTokens)
                    ),
                    requestCount: Self.periodDelta(
                        current: Double(summary.requestCount),
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

                return UsageComparisonItem(
                    objectId: row.modelId,
                    objectName: row.modelName,
                    summary: summary,
                    quality: quality,
                    periodComparison: periodComparison
                )
            }
            .sorted { lhs, rhs in
                if lhs.summary.totalTokens != rhs.summary.totalTokens {
                    return lhs.summary.totalTokens > rhs.summary.totalTokens
                }
                return lhs.objectName.localizedCaseInsensitiveCompare(rhs.objectName) == .orderedAscending
            }

        let totalSummary = ProviderUsageSummaryBlock(
            promptTokens: items.reduce(0) { $0 + $1.summary.promptTokens },
            completionTokens: items.reduce(0) { $0 + $1.summary.completionTokens },
            totalTokens: items.reduce(0) { $0 + $1.summary.totalTokens },
            requestCount: items.reduce(0) { $0 + $1.summary.requestCount },
            succeededCount: items.reduce(0) { $0 + $1.summary.succeededCount },
            failedCount: items.reduce(0) { $0 + $1.summary.failedCount },
            missingUsageCount: items.reduce(0) { $0 + $1.summary.missingUsageCount }
        )

        return UsageComparisonSnapshot(
            windowPreset: windowPreset,
            interval: interval,
            summary: totalSummary,
            quality: Self.qualityMetrics(from: totalSummary),
            items: items
        )
    }

    func fetchAgentUsageComparisonReport(
        windowPreset: UsageReportWindowPreset,
        providerProfileId: Int64? = nil,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> UsageComparisonSnapshot {
        let interval = windowPreset.interval(referenceDate: referenceDate, calendar: calendar)
        let previousInterval = DateInterval(
            start: calendar.date(byAdding: .day, value: -windowPreset.dayCount, to: interval.start) ?? interval.start,
            end: interval.start
        )

        let currentRows = try await fetchAgentUsageComparisonRows(
            interval: interval,
            providerProfileId: providerProfileId
        )
        let previousRows = try await fetchAgentUsageComparisonRows(
            interval: previousInterval,
            providerProfileId: providerProfileId
        )

        let currentByTask = Dictionary(uniqueKeysWithValues: currentRows.map { ($0.taskType, $0) })
        let previousByTask = Dictionary(uniqueKeysWithValues: previousRows.map { ($0.taskType, $0) })

        let tasks: [AgentTaskType] = [.summary, .translation]
        let items = tasks.enumerated().map { index, taskType -> UsageComparisonItem in
            let current = currentByTask[taskType]
            let previous = previousByTask[taskType]

            let summary = ProviderUsageSummaryBlock(
                promptTokens: current?.promptTokens ?? 0,
                completionTokens: current?.completionTokens ?? 0,
                totalTokens: current?.totalTokens ?? 0,
                requestCount: current?.requestCount ?? 0,
                succeededCount: current?.succeededCount ?? 0,
                failedCount: current?.failedCount ?? 0,
                missingUsageCount: current?.missingUsageCount ?? 0
            )
            let quality = Self.qualityMetrics(from: summary)

            let previousSummary = ProviderUsageSummaryBlock(
                promptTokens: previous?.promptTokens ?? 0,
                completionTokens: previous?.completionTokens ?? 0,
                totalTokens: previous?.totalTokens ?? 0,
                requestCount: previous?.requestCount ?? 0,
                succeededCount: previous?.succeededCount ?? 0,
                failedCount: previous?.failedCount ?? 0,
                missingUsageCount: previous?.missingUsageCount ?? 0
            )
            let previousQuality = Self.qualityMetrics(from: previousSummary)

            let periodComparison = ProviderUsagePeriodComparison(
                totalTokens: Self.periodDelta(
                    current: Double(summary.totalTokens),
                    previous: Double(previousSummary.totalTokens)
                ),
                requestCount: Self.periodDelta(
                    current: Double(summary.requestCount),
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

            return UsageComparisonItem(
                objectId: Int64(index + 1),
                objectName: String(localized: taskType.usageReportComparisonNameKey, bundle: LanguageManager.shared.bundle),
                summary: summary,
                quality: quality,
                periodComparison: periodComparison
            )
        }

        let totalSummary = ProviderUsageSummaryBlock(
            promptTokens: items.reduce(0) { $0 + $1.summary.promptTokens },
            completionTokens: items.reduce(0) { $0 + $1.summary.completionTokens },
            totalTokens: items.reduce(0) { $0 + $1.summary.totalTokens },
            requestCount: items.reduce(0) { $0 + $1.summary.requestCount },
            succeededCount: items.reduce(0) { $0 + $1.summary.succeededCount },
            failedCount: items.reduce(0) { $0 + $1.summary.failedCount },
            missingUsageCount: items.reduce(0) { $0 + $1.summary.missingUsageCount }
        )

        return UsageComparisonSnapshot(
            windowPreset: windowPreset,
            interval: interval,
            summary: totalSummary,
            quality: Self.qualityMetrics(from: totalSummary),
            items: items
        )
    }

    func fetchUsageReport(
        query: UsageReportQuery,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> ProviderUsageReportSnapshot {
        let interval = query.windowPreset.interval(referenceDate: referenceDate, calendar: calendar)
        let previousInterval = DateInterval(
            start: calendar.date(byAdding: .day, value: -query.windowPreset.dayCount, to: interval.start) ?? interval.start,
            end: interval.start
        )
        let formatter = Self.usageReportDateFormatter(calendar: calendar)

        let rows = try await fetchUsageDailyRows(
            query: query,
            interval: interval
        )
        let previousRows = try await fetchUsageDailyRows(
            query: query,
            interval: previousInterval
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

        let providerId: Int64
        switch query.scope {
        case let .provider(id):
            providerId = id
        case .model, .agent:
            providerId = 0
        }

        return ProviderUsageReportSnapshot(
            providerId: providerId,
            windowPreset: query.windowPreset,
            interval: interval,
            dailyBuckets: dailyBuckets,
            summary: currentSummary,
            quality: quality,
            periodComparison: periodComparison
        )
    }

    func fetchProviderUsageReport(
        providerId: Int64,
        windowPreset: UsageReportWindowPreset,
        taskType: AgentTaskType? = nil,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> ProviderUsageReportSnapshot {
        try await fetchUsageReport(
            query: UsageReportQuery(
                scope: .provider(id: providerId),
                windowPreset: windowPreset,
                secondaryFilter: .taskAggregation(taskType)
            ),
            referenceDate: referenceDate,
            calendar: calendar
        )
    }

    private func fetchUsageDailyRows(
        query: UsageReportQuery,
        interval: DateInterval,
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
                WHERE createdAt >= ?
                    AND createdAt < ?
                """
            var arguments: [DatabaseValueConvertible] = [
                LLMUsageRequestStatus.succeeded.rawValue,
                LLMUsageRequestStatus.failed.rawValue,
                LLMUsageRequestStatus.cancelled.rawValue,
                LLMUsageRequestStatus.timedOut.rawValue,
                LLMUsageAvailability.missing.rawValue,
                interval.start,
                interval.end
            ]

            switch query.scope {
            case let .provider(id):
                sql += "\n    AND providerProfileId = ?"
                arguments.append(id)
            case let .model(id):
                sql += "\n    AND modelProfileId = ?"
                arguments.append(id)
            case let .agent(taskType):
                sql += "\n    AND taskType = ?"
                arguments.append(taskType.rawValue)
            }

            switch query.secondaryFilter {
            case .none:
                break
            case let .taskAggregation(taskType):
                if let taskType {
                    sql += "\n    AND taskType = ?"
                    arguments.append(taskType.rawValue)
                }
            case let .providerSelection(providerId):
                if let providerId {
                    sql += "\n    AND providerProfileId = ?"
                    arguments.append(providerId)
                }
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

    private func fetchProviderUsageComparisonRows(
        interval: DateInterval,
        taskType: AgentTaskType?
    ) async throws -> [ProviderUsageComparisonRow] {
        try await database.read { db in
            var sql = """
                SELECT
                    p.id AS providerId,
                    COALESCE(p.name, '') AS providerName,
                    COALESCE(SUM(u.promptTokens), 0) AS promptTokens,
                    COALESCE(SUM(u.completionTokens), 0) AS completionTokens,
                    COALESCE(SUM(u.totalTokens), 0) AS totalTokens,
                    COUNT(u.id) AS requestCount,
                    COALESCE(SUM(CASE WHEN u.requestStatus = ? THEN 1 ELSE 0 END), 0) AS succeededCount,
                    COALESCE(SUM(CASE WHEN u.requestStatus IN (?, ?, ?) THEN 1 ELSE 0 END), 0) AS failedCount,
                    COALESCE(SUM(CASE WHEN u.usageAvailability = ? THEN 1 ELSE 0 END), 0) AS missingUsageCount
                FROM agent_provider_profile p
                LEFT JOIN llm_usage_event u
                    ON u.providerProfileId = p.id
                    AND u.createdAt >= ?
                    AND u.createdAt < ?
                """

            var arguments: [DatabaseValueConvertible] = [
                LLMUsageRequestStatus.succeeded.rawValue,
                LLMUsageRequestStatus.failed.rawValue,
                LLMUsageRequestStatus.cancelled.rawValue,
                LLMUsageRequestStatus.timedOut.rawValue,
                LLMUsageAvailability.missing.rawValue,
                interval.start,
                interval.end
            ]

            if let taskType {
                sql += "\n    AND u.taskType = ?"
                arguments.append(taskType.rawValue)
            }

            sql += """

                GROUP BY p.id
                ORDER BY totalTokens DESC
                """

            return try ProviderUsageComparisonRow.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(arguments)
            )
        }
    }

    private func fetchModelUsageComparisonRows(
        interval: DateInterval,
        taskType: AgentTaskType?
    ) async throws -> [ModelUsageComparisonRow] {
        try await database.read { db in
            var sql = """
                SELECT
                    m.id AS modelId,
                    COALESCE(m.name, '') AS modelName,
                    COALESCE(SUM(u.promptTokens), 0) AS promptTokens,
                    COALESCE(SUM(u.completionTokens), 0) AS completionTokens,
                    COALESCE(SUM(u.totalTokens), 0) AS totalTokens,
                    COUNT(u.id) AS requestCount,
                    COALESCE(SUM(CASE WHEN u.requestStatus = ? THEN 1 ELSE 0 END), 0) AS succeededCount,
                    COALESCE(SUM(CASE WHEN u.requestStatus IN (?, ?, ?) THEN 1 ELSE 0 END), 0) AS failedCount,
                    COALESCE(SUM(CASE WHEN u.usageAvailability = ? THEN 1 ELSE 0 END), 0) AS missingUsageCount
                FROM agent_model_profile m
                LEFT JOIN llm_usage_event u
                    ON u.modelProfileId = m.id
                    AND u.createdAt >= ?
                    AND u.createdAt < ?
                """

            var arguments: [DatabaseValueConvertible] = [
                LLMUsageRequestStatus.succeeded.rawValue,
                LLMUsageRequestStatus.failed.rawValue,
                LLMUsageRequestStatus.cancelled.rawValue,
                LLMUsageRequestStatus.timedOut.rawValue,
                LLMUsageAvailability.missing.rawValue,
                interval.start,
                interval.end
            ]

            if let taskType {
                sql += "\n    AND u.taskType = ?"
                arguments.append(taskType.rawValue)
            }

            sql += """

                GROUP BY m.id
                ORDER BY totalTokens DESC
                """

            return try ModelUsageComparisonRow.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(arguments)
            )
        }
    }

    private func fetchAgentUsageComparisonRows(
        interval: DateInterval,
        providerProfileId: Int64?
    ) async throws -> [AgentUsageComparisonRow] {
        try await database.read { db in
            var sql = """
                SELECT
                    u.taskType AS taskType,
                    COALESCE(SUM(u.promptTokens), 0) AS promptTokens,
                    COALESCE(SUM(u.completionTokens), 0) AS completionTokens,
                    COALESCE(SUM(u.totalTokens), 0) AS totalTokens,
                    COUNT(u.id) AS requestCount,
                    COALESCE(SUM(CASE WHEN u.requestStatus = ? THEN 1 ELSE 0 END), 0) AS succeededCount,
                    COALESCE(SUM(CASE WHEN u.requestStatus IN (?, ?, ?) THEN 1 ELSE 0 END), 0) AS failedCount,
                    COALESCE(SUM(CASE WHEN u.usageAvailability = ? THEN 1 ELSE 0 END), 0) AS missingUsageCount
                FROM llm_usage_event u
                WHERE u.createdAt >= ?
                    AND u.createdAt < ?
                    AND u.taskType IN (?, ?)
                """

            var arguments: [DatabaseValueConvertible] = [
                LLMUsageRequestStatus.succeeded.rawValue,
                LLMUsageRequestStatus.failed.rawValue,
                LLMUsageRequestStatus.cancelled.rawValue,
                LLMUsageRequestStatus.timedOut.rawValue,
                LLMUsageAvailability.missing.rawValue,
                interval.start,
                interval.end,
                AgentTaskType.summary.rawValue,
                AgentTaskType.translation.rawValue
            ]

            if let providerProfileId {
                sql += "\n    AND u.providerProfileId = ?"
                arguments.append(providerProfileId)
            }

            sql += """

                GROUP BY u.taskType
                """

            return try AgentUsageComparisonRow.fetchAll(
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

private struct ProviderUsageComparisonRow: FetchableRecord {
    let providerId: Int64
    let providerName: String
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let succeededCount: Int
    let failedCount: Int
    let missingUsageCount: Int

    init(row: Row) {
        providerId = row["providerId"]
        let rawName: String = row["providerName"]
        providerName = rawName.isEmpty ? "Provider #\(providerId)" : rawName
        promptTokens = row["promptTokens"]
        completionTokens = row["completionTokens"]
        totalTokens = row["totalTokens"]
        requestCount = row["requestCount"]
        succeededCount = row["succeededCount"]
        failedCount = row["failedCount"]
        missingUsageCount = row["missingUsageCount"]
    }
}

private struct ModelUsageComparisonRow: FetchableRecord {
    let modelId: Int64
    let modelName: String
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let succeededCount: Int
    let failedCount: Int
    let missingUsageCount: Int

    init(row: Row) {
        modelId = row["modelId"]
        let rawName: String = row["modelName"]
        modelName = rawName.isEmpty ? "Model #\(modelId)" : rawName
        promptTokens = row["promptTokens"]
        completionTokens = row["completionTokens"]
        totalTokens = row["totalTokens"]
        requestCount = row["requestCount"]
        succeededCount = row["succeededCount"]
        failedCount = row["failedCount"]
        missingUsageCount = row["missingUsageCount"]
    }
}

private struct AgentUsageComparisonRow: FetchableRecord {
    let taskType: AgentTaskType
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let succeededCount: Int
    let failedCount: Int
    let missingUsageCount: Int

    init(row: Row) {
        let rawTaskType: String = row["taskType"]
        taskType = AgentTaskType(rawValue: rawTaskType) ?? .summary
        promptTokens = row["promptTokens"]
        completionTokens = row["completionTokens"]
        totalTokens = row["totalTokens"]
        requestCount = row["requestCount"]
        succeededCount = row["succeededCount"]
        failedCount = row["failedCount"]
        missingUsageCount = row["missingUsageCount"]
    }
}

private extension AgentTaskType {
    var usageReportComparisonNameKey: String.LocalizationValue {
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
