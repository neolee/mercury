import SwiftUI

struct AgentUsageReportView: View {
    @Environment(\.localizationBundle) private var bundle
    @EnvironmentObject private var appModel: AppModel

    let context: AgentUsageReportContext

    @State private var windowPreset: UsageReportWindowPreset = .last1Week
    @State private var selectedProviderId: Int64?
    @State private var providers: [AgentProviderProfile] = []

    var body: some View {
        UsageReportView(
            titleKey: "Agent Statistics",
            subtitle: String(localized: context.taskType.usageReportTitleKey, bundle: bundle),
            isArchived: false,
            windowPreset: $windowPreset,
            reloadID: reloadID,
            loadSnapshot: { windowPreset in
                try await appModel.fetchUsageReport(
                    query: UsageReportQuery(
                        scope: .agent(taskType: context.taskType),
                        windowPreset: windowPreset,
                        secondaryFilter: .providerSelection(providerId: selectedProviderId)
                    )
                )
            },
            secondaryFilterContent: {
                HStack(spacing: 10) {
                    Text("Provider", bundle: bundle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)

                    Picker("", selection: $selectedProviderId) {
                        Text("All", bundle: bundle).tag(Optional<Int64>.none)
                        ForEach(providerItems, id: \.id) { item in
                            Text(item.name).tag(Optional<Int64>.some(item.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 240, alignment: .leading)
                }
            }
        )
        .environmentObject(appModel)
        .environment(\.localizationBundle, bundle)
        .task {
            await loadProviderItems()
        }
    }

    private var providerItems: [(id: Int64, name: String)] {
        providers
            .filter { !$0.isArchived }
            .compactMap { provider in
                guard let id = provider.id else { return nil }
                return (id, provider.name)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private var reloadID: String {
        "\(windowPreset.rawValue)-\(selectedProviderId.map(String.init) ?? "all")"
    }

    @MainActor
    private func loadProviderItems() async {
        do {
            providers = try await appModel.loadAgentProviderProfiles()
        } catch {
            providers = []
        }
    }
}

private extension AgentTaskType {
    var usageReportTitleKey: String.LocalizationValue {
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
