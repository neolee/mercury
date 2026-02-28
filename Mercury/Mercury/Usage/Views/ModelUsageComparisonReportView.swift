import SwiftUI

struct ModelUsageComparisonReportView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.localizationBundle) private var bundle

    @State private var windowPreset: UsageReportWindowPreset = .last1Week
    @State private var taskAggregation: UsageReportTaskAggregation = .all
    @State private var selectedMetric: UsageComparisonMetric = .totalTokens

    var body: some View {
        UsageComparisonReportView(
            titleKey: "Model Comparison",
            objectLabelKey: "Model",
            windowPreset: $windowPreset,
            metric: $selectedMetric,
            reloadID: reloadID,
            loadSnapshot: { windowPreset in
                try await appModel.fetchModelUsageComparisonReport(
                    windowPreset: windowPreset,
                    taskType: taskAggregation.taskType
                )
            },
            secondaryFilterContent: {
                HStack(spacing: 12) {
                    Text("Task", bundle: bundle)
                        .foregroundStyle(.secondary)

                    Picker("", selection: $taskAggregation) {
                        ForEach(UsageReportTaskAggregation.options, id: \.self) { option in
                            Text(option.labelKey, bundle: bundle).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
        )
    }

    private var reloadID: String {
        "\(windowPreset.rawValue)-\(taskAggregation.rawValueForTaskID)-\(selectedMetric.rawValue)"
    }
}
