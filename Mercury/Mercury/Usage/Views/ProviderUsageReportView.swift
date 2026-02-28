import Charts
import SwiftUI

struct ProviderUsageReportView: View {
    @Environment(\.localizationBundle) private var bundle
    @EnvironmentObject private var appModel: AppModel

    let context: ProviderUsageReportContext

    @State private var windowPreset: UsageReportWindowPreset = .last1Week
    @State private var taskAggregation: UsageReportTaskAggregation = .all

    var body: some View {
        UsageReportView(
            titleKey: "Provider Statistics",
            subtitle: context.providerName,
            isArchived: context.isArchived,
            windowPreset: $windowPreset,
            reloadID: taskID,
            loadSnapshot: { windowPreset in
                try await appModel.fetchUsageReport(
                    query: UsageReportQuery(
                        scope: .provider(id: context.id),
                        windowPreset: windowPreset,
                        secondaryFilter: .taskAggregation(taskAggregation.taskType)
                    )
                )
            },
            secondaryFilterContent: {
                HStack(spacing: 12) {
                    Text("Task", bundle: bundle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)

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
        .environmentObject(appModel)
        .environment(\.localizationBundle, bundle)
    }

    private var taskID: String {
        "\(windowPreset.rawValue)-\(taskAggregation.rawValueForTaskID)"
    }
}
