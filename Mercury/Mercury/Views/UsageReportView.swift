import Charts
import SwiftUI

private enum UsageReportLoadState {
    case loading
    case empty(ProviderUsageReportSnapshot)
    case data(ProviderUsageReportSnapshot)
    case error(String)
}

struct UsageReportView<SecondaryFilterContent: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.localizationBundle) private var bundle

    let titleKey: LocalizedStringKey
    let subtitle: String
    let isArchived: Bool
    @Binding var windowPreset: UsageReportWindowPreset
    let reloadID: String
    let loadSnapshot: @Sendable (UsageReportWindowPreset) async throws -> ProviderUsageReportSnapshot
    @ViewBuilder let secondaryFilterContent: () -> SecondaryFilterContent

    @State private var reportState: UsageReportLoadState = .loading
    @State private var hoveredBucket: ProviderUsageDailyBucket?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(titleKey, bundle: bundle)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                if isArchived {
                    Text("Archived", bundle: bundle)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }

                Spacer()

                Button(action: { dismiss() }) {
                    Text("Done", bundle: bundle)
                }
            }

            HStack(spacing: 32) {
                HStack(spacing: 12) {
                    Text("Window", bundle: bundle)
                        .foregroundStyle(.secondary)

                    Picker("", selection: $windowPreset) {
                        ForEach(UsageReportWindowPreset.allCases, id: \.self) { preset in
                            Text(preset.labelKey, bundle: bundle).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                secondaryFilterContent()

                Spacer()
            }

            contentView

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 660, alignment: .topLeading)
        .task(id: reloadID) {
            await reloadReport()
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch reportState {
        case .loading:
            reportCard {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading usage data...", bundle: bundle)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .empty:
            reportCard {
                VStack(spacing: 10) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("No usage data in this period.", bundle: bundle)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case let .error(message):
            reportCard {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("Failed to load usage data.", bundle: bundle)
                        .fontWeight(.semibold)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(action: { Task { await reloadReport() } }) {
                        Text("Retry", bundle: bundle)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case let .data(snapshot):
            reportCard {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        let upLabel = String(localized: "Up", bundle: bundle)
                        let downLabel = String(localized: "Down", bundle: bundle)
                        let lineScale = requestScale(for: snapshot)

                        Chart {
                            ForEach(snapshot.dailyBuckets) { bucket in
                                BarMark(
                                    x: .value("Day", bucket.dayStart),
                                    y: .value("Up Tokens", bucket.promptTokens)
                                )
                                .position(by: .value("Series", "Tokens"))
                                .foregroundStyle(by: .value("Token Type", upLabel))

                                BarMark(
                                    x: .value("Day", bucket.dayStart),
                                    y: .value("Down Tokens", bucket.completionTokens)
                                )
                                .position(by: .value("Series", "Tokens"))
                                .foregroundStyle(by: .value("Token Type", downLabel))

                                LineMark(
                                    x: .value("Day", bucket.dayStart),
                                    y: .value("Requests (Scaled)", Double(bucket.requestCount) * lineScale)
                                )
                                .position(by: .value("Series", "Requests"))
                                .interpolationMethod(.catmullRom)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                                .foregroundStyle(.secondary)
                            }
                        }
                        .chartForegroundStyleScale([
                            upLabel: Color.accentColor,
                            downLabel: Color.secondary.opacity(0.6)
                        ])
                        .chartYAxis {
                            AxisMarks(position: .leading) { value in
                                AxisGridLine()
                                AxisTick()
                                if let tokenValue = value.as(Double.self), lineScale > 0 {
                                    let requestValue = tokenValue / lineScale
                                    AxisValueLabel {
                                        Text(requestValue.formatted(.number.precision(.fractionLength(0))))
                                    }
                                }
                            }

                            AxisMarks(position: .trailing) { value in
                                AxisGridLine()
                                AxisTick()
                                AxisValueLabel()
                            }
                        }
                        .chartPlotStyle { plotContent in
                            plotContent
                                .clipped()
                        }
                        .chartOverlay { proxy in
                            GeometryReader { geometry in
                                Rectangle()
                                    .fill(.clear)
                                    .contentShape(Rectangle())
                                    .onContinuousHover { phase in
                                        switch phase {
                                        case let .active(location):
                                            guard let plotFrame = proxy.plotFrame else {
                                                hoveredBucket = nil
                                                return
                                            }
                                            let frame = geometry[plotFrame]
                                            let x = location.x - frame.origin.x
                                            guard x >= 0, x <= proxy.plotSize.width,
                                                  let date: Date = proxy.value(atX: x) else {
                                                hoveredBucket = nil
                                                return
                                            }
                                            hoveredBucket = nearestDailyBucket(
                                                to: date,
                                                from: snapshot.dailyBuckets
                                            )
                                        case .ended:
                                            hoveredBucket = nil
                                        }
                                    }
                            }
                        }
                        .padding(.top, 8)
                        .frame(height: 300)

                        if let hoveredBucket {
                            hoveredDataPanel(bucket: hoveredBucket)
                        } else {
                            Text("Hover over chart to inspect daily values.", bundle: bundle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 16) {
                            Text(String(format: String(localized: "Requests: %d", bundle: bundle), snapshot.summary.requestCount))
                            Text(String(format: String(localized: "Tokens: %d", bundle: bundle), snapshot.summary.totalTokens))
                        }
                        .foregroundStyle(.secondary)

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Quality", bundle: bundle)
                                .font(.headline)

                            HStack(spacing: 18) {
                                Text("Success Rate", bundle: bundle)
                                Text(percentageText(snapshot.quality.successRate))
                                    .foregroundStyle(.secondary)

                                Text("Usage Coverage", bundle: bundle)
                                Text(percentageText(snapshot.quality.usageCoverageRate))
                                    .foregroundStyle(.secondary)

                                Text("Avg Tokens / Request", bundle: bundle)
                                Text(numberText(snapshot.quality.averageTokensPerRequest))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Period-over-Period", bundle: bundle)
                                .font(.headline)

                            HStack(spacing: 14) {
                                periodDeltaCell(title: "Tokens", delta: snapshot.periodComparison.totalTokens)
                                periodDeltaCell(title: "Requests", delta: snapshot.periodComparison.requestCount)
                                periodDeltaCell(title: "Success", delta: snapshot.periodComparison.successRate, asPercent: true)
                                periodDeltaCell(title: "Coverage", delta: snapshot.periodComparison.usageCoverageRate, asPercent: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func reportCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(content())
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.6)
            )
    }

    @MainActor
    private func reloadReport() async {
        reportState = .loading
        hoveredBucket = nil
        do {
            let snapshot = try await loadSnapshot(windowPreset)
            reportState = snapshot.summary.requestCount == 0 ? .empty(snapshot) : .data(snapshot)
        } catch {
            if error is CancellationError {
                return
            }
            reportState = .error(error.localizedDescription)
        }
    }

    private func requestScale(for snapshot: ProviderUsageReportSnapshot) -> Double {
        let maxRequests = snapshot.dailyBuckets.map(\.requestCount).max() ?? 0
        let maxTokens = snapshot.dailyBuckets.map(\.totalTokens).max() ?? 0
        guard maxRequests > 0 else {
            return 1
        }
        return maxTokens > 0 ? Double(maxTokens) / Double(maxRequests) : 1
    }

    private func nearestDailyBucket(
        to date: Date,
        from buckets: [ProviderUsageDailyBucket]
    ) -> ProviderUsageDailyBucket? {
        buckets.min(by: {
            abs($0.dayStart.timeIntervalSince(date)) < abs($1.dayStart.timeIntervalSince(date))
        })
    }

    private func hoveredDataPanel(bucket: ProviderUsageDailyBucket) -> some View {
        HStack(spacing: 14) {
            Text(bucket.dayStart, format: .dateTime.year().month().day())
                .fontWeight(.semibold)

            Text("Up", bundle: bundle)
            Text(numberText(Double(bucket.promptTokens)))
                .foregroundStyle(.secondary)

            Text("Down", bundle: bundle)
            Text(numberText(Double(bucket.completionTokens)))
                .foregroundStyle(.secondary)

            Text("Requests", bundle: bundle)
            Text(numberText(Double(bucket.requestCount)))
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
    }

    private func percentageText(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(1)))
    }

    private func numberText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func periodDeltaCell(title: LocalizedStringKey, delta: ProviderUsagePeriodDelta, asPercent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title, bundle: bundle)
                .font(.caption)

            Text(deltaValueText(delta, asPercent: asPercent))
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(delta.delta >= 0 ? .primary : .secondary)

            Text(deltaRatioText(delta))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func deltaValueText(_ delta: ProviderUsagePeriodDelta, asPercent: Bool) -> String {
        if asPercent {
            let points = delta.delta * 100
            return points.formatted(.number.precision(.fractionLength(1))) + "pp"
        }
        return (delta.delta >= 0 ? "+" : "") + delta.delta.formatted(.number.precision(.fractionLength(1)))
    }

    private func deltaRatioText(_ delta: ProviderUsagePeriodDelta) -> String {
        guard let ratio = delta.deltaRatio else {
            return String(localized: "vs previous: n/a", bundle: bundle)
        }
        let sign = ratio >= 0 ? "+" : ""
        return String(localized: "vs previous: ", bundle: bundle) + sign + ratio.formatted(.percent.precision(.fractionLength(1)))
    }
}

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

private extension AgentTaskType {
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
