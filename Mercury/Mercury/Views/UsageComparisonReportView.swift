import Charts
import SwiftUI

enum UsageComparisonMetric: String, CaseIterable {
    case totalTokens
    case promptTokens
    case completionTokens
    case requests

    var labelKey: LocalizedStringKey {
        switch self {
        case .totalTokens:
            return "Tokens"
        case .promptTokens:
            return "Up Tokens"
        case .completionTokens:
            return "Down Tokens"
        case .requests:
            return "Requests"
        }
    }

    func numericValue(for item: ProviderUsageComparisonItem) -> Double {
        switch self {
        case .totalTokens:
            return Double(item.summary.totalTokens)
        case .promptTokens:
            return Double(item.summary.promptTokens)
        case .completionTokens:
            return Double(item.summary.completionTokens)
        case .requests:
            return Double(item.summary.requestCount)
        }
    }
}

private enum UsageComparisonLoadState {
    case loading
    case empty(ProviderUsageComparisonSnapshot)
    case data(ProviderUsageComparisonSnapshot)
    case error(String)
}

struct UsageComparisonReportView<SecondaryFilterContent: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.localizationBundle) private var bundle

    let titleKey: LocalizedStringKey
    let objectLabelKey: LocalizedStringKey
    @Binding var windowPreset: UsageReportWindowPreset
    @Binding var metric: UsageComparisonMetric
    let reloadID: String
    let loadSnapshot: @Sendable (UsageReportWindowPreset) async throws -> ProviderUsageComparisonSnapshot
    @ViewBuilder let secondaryFilterContent: () -> SecondaryFilterContent

    @State private var state: UsageComparisonLoadState = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(titleKey, bundle: bundle)
                    .font(.title2)
                    .fontWeight(.semibold)

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

                HStack(spacing: 12) {
                    Text("Series", bundle: bundle)
                        .foregroundStyle(.secondary)

                    Picker("", selection: $metric) {
                        ForEach(UsageComparisonMetric.allCases, id: \.self) { metricOption in
                            Text(metricOption.labelKey, bundle: bundle).tag(metricOption)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                Spacer()
            }

            content

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 960, minHeight: 680, alignment: .topLeading)
        .task(id: reloadID) {
            await reload()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            card {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading usage data...", bundle: bundle)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .empty:
            card {
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
            card {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("Failed to load usage data.", bundle: bundle)
                        .fontWeight(.semibold)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(action: { Task { await reload() } }) {
                        Text("Retry", bundle: bundle)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case let .data(snapshot):
            card {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 16) {
                            Text(String(format: String(localized: "Requests: %d", bundle: bundle), snapshot.summary.requestCount))
                            Text(String(format: String(localized: "Tokens: %d", bundle: bundle), snapshot.summary.totalTokens))
                            Text("Success Rate", bundle: bundle)
                            Text(snapshot.quality.successRate.formatted(.percent.precision(.fractionLength(1))))
                                .foregroundStyle(.secondary)
                            Text("Usage Coverage", bundle: bundle)
                            Text(snapshot.quality.usageCoverageRate.formatted(.percent.precision(.fractionLength(1))))
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.secondary)

                        ScrollView(.horizontal) {
                            Chart(displayedItems(snapshot)) { item in
                                BarMark(
                                    x: .value("Object", item.providerName),
                                    y: .value("Value", metric.numericValue(for: item))
                                )
                                .foregroundStyle(Color.accentColor)
                            }
                            .frame(
                                width: max(880, CGFloat(displayedItems(snapshot).count) * 72),
                                height: 260
                            )
                            .padding(.top, 16)
                        }
                        .padding(.bottom, 16)

                        VStack(alignment: .leading, spacing: 8) {
                            headerRow

                            ForEach(displayedItems(snapshot)) { item in
                                Divider()
                                dataRow(item)
                            }
                        }
                        .font(.subheadline)
                    }
                    .padding(14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    @MainActor
    private func reload() async {
        state = .loading
        do {
            let snapshot = try await loadSnapshot(windowPreset)
            state = snapshot.items.isEmpty ? .empty(snapshot) : .data(snapshot)
        } catch {
            if error is CancellationError {
                return
            }
            state = .error(error.localizedDescription)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(content())
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.6)
            )
    }

    private func displayedItems(_ snapshot: ProviderUsageComparisonSnapshot) -> [ProviderUsageComparisonItem] {
        snapshot.items.sorted { lhs, rhs in
            let left = metric.numericValue(for: lhs)
            let right = metric.numericValue(for: rhs)
            if left != right {
                return left > right
            }
            return lhs.providerName.localizedCaseInsensitiveCompare(rhs.providerName) == .orderedAscending
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(objectLabelKey, bundle: bundle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Up", bundle: bundle)
                .frame(width: 90, alignment: .trailing)
            Text("Down", bundle: bundle)
                .frame(width: 90, alignment: .trailing)
            Text("Tokens", bundle: bundle)
                .frame(width: 110, alignment: .trailing)
            Text("Requests", bundle: bundle)
                .frame(width: 90, alignment: .trailing)
            Text("Success Rate", bundle: bundle)
                .frame(width: 110, alignment: .trailing)
            Text("Usage Coverage", bundle: bundle)
                .frame(width: 120, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func dataRow(_ item: ProviderUsageComparisonItem) -> some View {
        HStack(spacing: 8) {
            Text(item.providerName)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.summary.promptTokens.formatted(.number))
                .frame(width: 90, alignment: .trailing)
            Text(item.summary.completionTokens.formatted(.number))
                .frame(width: 90, alignment: .trailing)
            Text(item.summary.totalTokens.formatted(.number))
                .frame(width: 110, alignment: .trailing)
            Text(item.summary.requestCount.formatted(.number))
                .frame(width: 90, alignment: .trailing)
            Text(item.quality.successRate.formatted(.percent.precision(.fractionLength(1))))
                .frame(width: 110, alignment: .trailing)
            Text(item.quality.usageCoverageRate.formatted(.percent.precision(.fractionLength(1))))
                .frame(width: 120, alignment: .trailing)
        }
    }
}
