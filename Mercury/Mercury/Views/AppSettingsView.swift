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
    @State private var usageRetentionPolicy: LLMUsageRetentionPolicy = .defaultValue
    @State private var showingUsageClearAllConfirm = false
    @State private var isCleaningUsageData = false
    @State private var usageDataStatusMessage: String = ""

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

                Section(String(localized: "Usage Data", bundle: bundle)) {
                    Picker(selection: usageRetentionPolicyBinding) {
                        ForEach(LLMUsageRetentionPolicy.allCases, id: \.self) { policy in
                            Text(policy.label, bundle: bundle).tag(policy)
                        }
                    } label: {
                        Text("Retention", bundle: bundle)
                    }

                    HStack(spacing: 12) {
                        Button(action: {
                            Task { await clearExpiredUsageData() }
                        }) {
                            Text("Clear Expired Usage Data", bundle: bundle)
                        }

                        Button(role: .destructive, action: {
                            showingUsageClearAllConfirm = true
                        }) {
                            Text("Clear All Usage Data", bundle: bundle)
                        }
                    }
                    .disabled(isCleaningUsageData)

                    if usageDataStatusMessage.isEmpty == false {
                        Text(usageDataStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text("Retention and clear actions affect only LLM usage events.", bundle: bundle)
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
            usageRetentionPolicy = appModel.loadLLMUsageRetentionPolicy()
        }
        .confirmationDialog(
            String(localized: "Clear All Usage Data", bundle: bundle),
            isPresented: $showingUsageClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive, action: {
                Task { await clearAllUsageData() }
            }) {
                Text("Clear All", bundle: bundle)
            }
            Button(role: .cancel, action: {}) {
                Text("Cancel", bundle: bundle)
            }
        } message: {
            Text("This removes all usage rows regardless of retention policy and keeps summaries, translations, and run records unchanged.", bundle: bundle)
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

    private var usageRetentionPolicyBinding: Binding<LLMUsageRetentionPolicy> {
        Binding(
            get: { usageRetentionPolicy },
            set: { newValue in
                usageRetentionPolicy = newValue
                appModel.saveLLMUsageRetentionPolicy(newValue)
            }
        )
    }

    @MainActor
    private func clearExpiredUsageData() async {
        isCleaningUsageData = true
        defer { isCleaningUsageData = false }

        do {
            let removedCount = try await appModel.purgeExpiredLLMUsageEvents()
            usageDataStatusMessage = String(
                format: String(localized: "Cleared %lld expired usage records.", bundle: bundle),
                Int64(removedCount)
            )
        } catch {
            usageDataStatusMessage = String(
                format: String(localized: "Failed to clear expired usage data: %@", bundle: bundle),
                error.localizedDescription
            )
        }
    }

    @MainActor
    private func clearAllUsageData() async {
        isCleaningUsageData = true
        defer { isCleaningUsageData = false }

        do {
            let removedCount = try await appModel.clearLLMUsageEvents()
            usageDataStatusMessage = String(
                format: String(localized: "Cleared %lld usage records.", bundle: bundle),
                Int64(removedCount)
            )
        } catch {
            usageDataStatusMessage = String(
                format: String(localized: "Failed to clear usage data: %@", bundle: bundle),
                error.localizedDescription
            )
        }
    }
}

private extension LLMUsageRetentionPolicy {
    var label: LocalizedStringKey {
        switch self {
        case .oneMonth:
            "1 month"
        case .threeMonths:
            "3 months"
        case .sixMonths:
            "6 months"
        case .oneYear:
            "12 months"
        case .forever:
            "Forever"
        }
    }
}
