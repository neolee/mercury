import SwiftUI

struct AppSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            ReaderSettingsView()
                .tabItem {
                    Label("Reader", systemImage: "text.book.closed")
                }

            AgentAssistantSettingsView()
                .tabItem {
                    Label("Agents", systemImage: "sparkles")
                }
        }
        .frame(minWidth: 920, minHeight: 620)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var syncFeedConcurrency: Int = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Sync") {
                    SettingsSliderRow(
                        title: "Feed Sync Concurrency",
                        valueText: "\(syncFeedConcurrency)",
                        value: syncFeedConcurrencySliderBinding,
                        range: 2...10,
                        valueMinWidth: 36
                    )

                    Text("Controls parallel feed update workers during full sync. Higher values can improve speed but may increase network load.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .onAppear {
            syncFeedConcurrency = appModel.syncFeedConcurrency
        }
    }

    private var syncFeedConcurrencySliderBinding: Binding<Double> {
        Binding(
            get: { Double(syncFeedConcurrency) },
            set: { newValue in
                let normalized = min(max(Int(newValue.rounded()), 2), 10)
                syncFeedConcurrency = normalized
                appModel.setSyncFeedConcurrency(normalized)
            }
        )
    }
}
