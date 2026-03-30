import AppKit
import SwiftUI

struct AppSettingsView: View {
    var bundle: Bundle { LanguageManager.shared.bundle }
    @AppStorage(AppSettingsNavigation.selectedTabDefaultsKey) private var selectedTabRawValue = AppSettingsTab.general.rawValue

    var body: some View {
        TabView(selection: selectedTabBinding) {
            GeneralSettingsView()
                .tag(AppSettingsTab.general)
                .tabItem {
                    Label(String(localized: "General", bundle: bundle), systemImage: "gearshape")
                }

            ReaderSettingsView()
                .tag(AppSettingsTab.reader)
                .tabItem {
                    Label(String(localized: "Reader", bundle: bundle), systemImage: "text.book.closed")
                }

            AgentSettingsView()
                .tag(AppSettingsTab.agents)
                .tabItem {
                    Label(String(localized: "Agents", bundle: bundle), systemImage: "sparkles")
                }

            DigestSettingsView()
                .tag(AppSettingsTab.digest)
                .tabItem {
                    Label(String(localized: "Digest", bundle: bundle), systemImage: "doc.plaintext")
                }
        }
        .frame(minWidth: 920, minHeight: 640)
        .environment(\.localizationBundle, LanguageManager.shared.bundle)
        .onReceive(NotificationCenter.default.publisher(for: .appSettingsSelectedTabDidChange)) { _ in
            selectedTabRawValue = AppSettingsNavigation.selectedTab().rawValue
        }
    }

    private var selectedTabBinding: Binding<AppSettingsTab> {
        Binding(
            get: { AppSettingsTab(rawValue: selectedTabRawValue) ?? .general },
            set: { selectedTabRawValue = $0.rawValue }
        )
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
    @State private var isShowingBatchTaggingSheet = false
    @State private var isShowingTagLibrarySheet = false
    @AppStorage("Agent.Tagging.Enabled") private var isTaggingAgentEnabled = false

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

                Section(String(localized: "Tag System", bundle: bundle)) {
                    Toggle(isOn: $isTaggingAgentEnabled) {
                        Text("Enable AI Tagging", bundle: bundle)
                    }
                    .disabled(!appModel.isTaggingAgentAvailable)

                    if !appModel.isTaggingAgentAvailable {
                        Text("Configure a model in Agents > Agents > Tagging to enable AI tagging.", bundle: bundle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button(action: {
                            isShowingBatchTaggingSheet = true
                        }) {
                            Text("Batch Tagging...", bundle: bundle)
                        }
                        .disabled(!appModel.isTaggingAgentAvailable || !isTaggingAgentEnabled)

                        Button(action: {
                            isShowingTagLibrarySheet = true
                        }) {
                            Text("Tag Library...", bundle: bundle)
                        }
                    }
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
            if appModel.isTaggingAgentAvailable == false {
                isTaggingAgentEnabled = false
            }
        }
        .onChange(of: appModel.isTaggingAgentAvailable) { _, isAvailable in
            if isAvailable == false {
                isTaggingAgentEnabled = false
            }
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
        .sheet(isPresented: $isShowingBatchTaggingSheet) {
            BatchTaggingSheetView()
                .environmentObject(appModel)
                .environment(\.localizationBundle, bundle)
                .interactiveDismissDisabled(appModel.isTagBatchLifecycleActive)
        }
        .sheet(isPresented: $isShowingTagLibrarySheet) {
            TagLibrarySheetView()
                .environmentObject(appModel)
                .environment(\.localizationBundle, bundle)
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

private struct DigestSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.localizationBundle) private var bundle
    @State private var exportDirectoryURL: URL?
    @State private var exportDirectoryStatus: DigestExportDirectoryStatus = .notConfigured

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section(String(localized: "Export", bundle: bundle)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "Local Export Path", bundle: bundle))
                            .font(.headline)

                        Text(exportDirectoryURL?.path ?? String(localized: "No export directory selected.", bundle: bundle))
                            .textSelection(.enabled)
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(exportDirectoryStatus.localizedStatusText(bundle: bundle))
                            .font(.footnote)
                            .foregroundStyle(exportDirectoryStatus.isAvailable ? Color.secondary : Color.orange)

                        if let recoveryMessage = exportDirectoryStatus.localizedRecoveryMessage(bundle: bundle) {
                            Text(recoveryMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            Button(String(localized: "Choose Export Folder...", bundle: bundle)) {
                                chooseExportDirectory()
                            }

                            Button(String(localized: "Reveal in Finder", bundle: bundle)) {
                                revealExportDirectory()
                            }
                            .disabled(exportDirectoryStatus.canRevealInFinder == false)

                            Button(String(localized: "Clear", bundle: bundle), role: .destructive) {
                                DigestExportPathStore.clearDirectory()
                                refreshExportDirectoryStatus()
                            }
                            .disabled(exportDirectoryURL == nil)
                        }

                        Text(
                            "Export Digest writes generated Markdown files to this folder, so you can publish or sync them to the service you use afterward.",
                            bundle: bundle
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section(String(localized: "Templates", bundle: bundle)) {
                    VStack(alignment: .leading, spacing: 12) {
                        digestTemplateRow(
                            title: String(localized: "Share Digest", bundle: bundle),
                            config: .shareDigest
                        )
                        digestTemplateRow(
                            title: String(localized: "Export Digest", bundle: bundle),
                            config: .exportDigest
                        )
                        digestTemplateRow(
                            title: String(localized: "Export Multiple Digest", bundle: bundle),
                            config: .exportMultipleDigest
                        )

                        Text(
                            "Here you can define your own version to override the built-in template. The first time you click Custom Template, Mercury creates the custom template file automatically and opens its folder so you can edit it.",
                            bundle: bundle
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                        Text(
                            "If loading a custom template fails, Mercury automatically falls back to the built-in template. Deleting the custom template file also restores the built-in template.",
                            bundle: bundle
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .onAppear {
            refreshExportDirectoryStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshExportDirectoryStatus()
        }
    }

    @MainActor
    private func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Choose Export Folder", bundle: bundle)

        if let exportDirectoryURL {
            panel.directoryURL = exportDirectoryURL
        }

        guard let hostWindow = NSApp.keyWindow ?? NSApp.mainWindow else {
            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }

            DigestExportPathStore.saveDirectory(url)
            refreshExportDirectoryStatus()
            return
        }

        panel.beginSheetModal(for: hostWindow) { response in
            guard response == .OK, let url = panel.url else {
                return
            }

            DigestExportPathStore.saveDirectory(url)
            refreshExportDirectoryStatus()
        }
    }

    private func revealExportDirectory() {
        guard let exportDirectoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportDirectoryURL])
    }

    @ViewBuilder
    private func digestTemplateRow(title: String, config: DigestTemplateCustomizationConfig) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(String(localized: "custom template", bundle: bundle)) {
                Task { @MainActor in
                    _ = try? appModel.revealCustomDigestTemplateInFinder(config: config)
                }
            }
            .buttonStyle(.link)
        }
    }

    private func refreshExportDirectoryStatus() {
        let status = DigestExportPathStore.currentDirectoryStatus()
        exportDirectoryStatus = status
        exportDirectoryURL = status.resolvedURL
    }
}

private extension LLMUsageRetentionPolicy {
    var label: LocalizedStringKey {
        switch self {
        case .oneMonth:
            "1 Month"
        case .threeMonths:
            "3 Months"
        case .sixMonths:
            "6 Months"
        case .oneYear:
            "12 Months"
        case .forever:
            "Forever"
        }
    }
}
