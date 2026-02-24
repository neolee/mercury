import SwiftUI

struct AgentUsageComparisonReportView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.localizationBundle) private var bundle

    @State private var windowPreset: UsageReportWindowPreset = .last1Week
    @State private var selectedProviderId: Int64?
    @State private var selectedMetric: UsageComparisonMetric = .totalTokens
    @State private var providers: [AgentProviderProfile] = []

    var body: some View {
        UsageComparisonReportView(
            titleKey: "Agent Comparison",
            objectLabelKey: "Agent",
            windowPreset: $windowPreset,
            metric: $selectedMetric,
            reloadID: reloadID,
            loadSnapshot: { windowPreset in
                try await appModel.fetchAgentUsageComparisonReport(
                    windowPreset: windowPreset,
                    providerProfileId: selectedProviderId
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
                    .frame(alignment: .leading)
                }
            }
        )
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
        "\(windowPreset.rawValue)-\(selectedProviderId.map(String.init) ?? "all")-\(selectedMetric.rawValue)"
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
