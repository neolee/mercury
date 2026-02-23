import SwiftUI

struct AppSettingsView: View {
    var bundle: Bundle { LanguageManager.shared.bundle }

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label(String(localized: "General", bundle: bundle), systemImage: "gearshape")
                }

            ReaderSettingsView()
                .tabItem {
                    Label(String(localized: "Reader", bundle: bundle), systemImage: "text.book.closed")
                }

            AgentSettingsView()
                .tabItem {
                    Label(String(localized: "Agents", bundle: bundle), systemImage: "sparkles")
                }
        }
        .frame(minWidth: 920, minHeight: 620)
        .environment(\.localizationBundle, LanguageManager.shared.bundle)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.localizationBundle) var bundle
    @State private var syncFeedConcurrency: Int = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section(String(localized: "Language", bundle: bundle)) {
                    Picker(selection: languageBinding) {
                        Text("System (auto-detect)", bundle: bundle).tag(Optional<String>.none)
                        ForEach(LanguageManager.supported) { lang in
                            Text(lang.displayName).tag(Optional<String>.some(lang.code))
                        }
                    } label: {
                        Text("Language", bundle: bundle)
                    }

                    Text("Overrides the system language for Mercury's interface.", bundle: bundle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "Sync", bundle: bundle)) {
                    SettingsSliderRow(
                        title: String(localized: "Feed Sync Concurrency", bundle: bundle),
                        valueText: "\(syncFeedConcurrency)",
                        value: syncFeedConcurrencySliderBinding,
                        range: 2...10,
                        valueMinWidth: 36
                    )

                    Text("Controls parallel feed update workers during full sync. Higher values can improve speed but may increase network load.", bundle: bundle)
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

    private var languageBinding: Binding<String?> {
        Binding(
            get: { LanguageManager.shared.languageOverride },
            set: { LanguageManager.shared.setLanguage($0) }
        )
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
