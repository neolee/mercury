import SwiftUI

struct AgentSettingsView: View {
    enum ProviderFocusField: Hashable {
        case displayName
    }

    enum ModelFocusField: Hashable {
        case profileName
    }

    @EnvironmentObject var appModel: AppModel
    @Environment(\.localizationBundle) var bundle
    @AppStorage("Agent.Summary.AutoSummaryEnableWarning") var summaryAutoEnableWarning: Bool = true
    @State var section: AgentSettingsSection = .provider

    @State var providers: [AgentProviderProfile] = []
    @State var selectedProviderId: Int64?
    @State var providerName: String = ""
    @State var providerBaseURL: String = "http://localhost:5810/v1"
    @State var providerAPIKey: String = ""
    @State var providerHasStoredAPIKey: Bool = false
    @State var providerEnabled: Bool = true
    @State var providerTestModel: String = "modelname"
    @State var isProviderTesting: Bool = false

    @State var models: [AgentModelProfile] = []
    @State var selectedModelId: Int64?
    @State var modelProviderId: Int64?
    @State var modelProfileName: String = ""
    @State var modelName: String = "qwen3"
    @State var modelShowAdvancedParameters: Bool = false
    @State var modelStreaming: Bool = true
    @State var modelTemperature: String = ""
    @State var modelTopP: String = ""
    @State var modelMaxTokens: String = ""
    @State var modelTestSystemMessage: String = "You are a concise agent."
    @State var modelTestUserMessage: String = "Reply with exactly: ok"
    @State var isModelTesting: Bool = false

    @State var selectedAgentTask: AgentTaskType = .summary
    @State var summaryPrimaryModelId: Int64?
    @State var summaryFallbackModelId: Int64?
    @State var translationPrimaryModelId: Int64?
    @State var translationFallbackModelId: Int64?
    @State var summaryDefaultTargetLanguage: String = "en"
    @State var translationDefaultTargetLanguage: String = "en"
    @State var summaryDefaultDetailLevel: SummaryDetailLevel = .medium
    @State var isApplyingAgentDefaults = false
    @State var suppressAgentDefaultsPersistence = true

    @State var statusText: String = String(localized: "Ready", bundle: LanguageManager.shared.bundle)
    @State var outputPreview: String = ""
    @State var latencyMs: Int?
    @State var pendingDeleteProviderId: Int64?
    @State var pendingDeleteProviderName: String = ""
    @State var pendingDeleteProviderModelNames: String = ""
    @State var showingProviderDeleteConfirm: Bool = false
    @State var pendingDeleteModelId: Int64?
    @State var pendingDeleteModelName: String = ""
    @State var showingModelDeleteConfirm: Bool = false
    @State var providerUsageReportContext: ProviderUsageReportContext?
    @State var modelUsageReportContext: ModelUsageReportContext?
    @State var agentUsageReportContext: AgentUsageReportContext?
    @State var showingProviderComparisonReport: Bool = false
    @FocusState var providerFocusedField: ProviderFocusField?
    @FocusState var modelFocusedField: ModelFocusField?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Picker("", selection: $section) {
                    Text("Providers", bundle: bundle).tag(AgentSettingsSection.provider)
                    Text("Models", bundle: bundle).tag(AgentSettingsSection.model)
                    Text("Agents", bundle: bundle).tag(AgentSettingsSection.agentTask)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Spacer()
            }

            HStack(spacing: 18) {
                leftPane
                    .frame(width: 200)
                    .padding(.top, 20)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        rightPane

                        if section != .agentTask {
                            resultSection
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await loadAgentSettingsData()
        }
        .onChange(of: summaryPrimaryModelId) { _, _ in
            guard shouldPersistAgentDefaultsOnChange else { return }
            persistSummaryAgentDefaults()
        }
        .onChange(of: summaryFallbackModelId) { _, _ in
            guard shouldPersistAgentDefaultsOnChange else { return }
            persistSummaryAgentDefaults()
        }
        .onChange(of: summaryDefaultTargetLanguage) { _, _ in
            guard shouldPersistAgentDefaultsOnChange else { return }
            persistSummaryAgentDefaults()
        }
        .onChange(of: summaryDefaultDetailLevel) { _, _ in
            guard shouldPersistAgentDefaultsOnChange else { return }
            persistSummaryAgentDefaults()
        }
        .onChange(of: translationPrimaryModelId) { _, _ in
            guard shouldPersistAgentDefaultsOnChange else { return }
            persistTranslationAgentDefaults()
        }
        .onChange(of: translationFallbackModelId) { _, _ in
            guard shouldPersistAgentDefaultsOnChange else { return }
            persistTranslationAgentDefaults()
        }
        .onChange(of: translationDefaultTargetLanguage) { _, _ in
            guard shouldPersistAgentDefaultsOnChange else { return }
            persistTranslationAgentDefaults()
        }
        .onChange(of: selectedProviderId) { _, newValue in
            guard let provider = providers.first(where: { $0.id == newValue }) else {
                providerHasStoredAPIKey = false
                return
            }
            applyProviderToForm(provider)
        }
        .onChange(of: selectedModelId) { _, newValue in
            guard let model = models.first(where: { $0.id == newValue }) else { return }
            applyModelToForm(model)
        }
        .confirmationDialog(
            String(localized: "Delete Provider", bundle: bundle),
            isPresented: $showingProviderDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive, action: { Task { await deleteProvider() } }) { Text("Delete", bundle: bundle) }
            Button(role: .cancel, action: {}) { Text("Cancel", bundle: bundle) }
        } message: {
            Text(
                String(
                    format: String(localized: "Delete \"%1$@\"? Related models will be archived: %2$@.", bundle: bundle),
                    pendingDeleteProviderName,
                    pendingDeleteProviderModelNames
                )
            )
        }
        .confirmationDialog(
            String(localized: "Delete Model", bundle: bundle),
            isPresented: $showingModelDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive, action: { Task { await deleteModel() } }) { Text("Delete", bundle: bundle) }
            Button(role: .cancel, action: {}) { Text("Cancel", bundle: bundle) }
        } message: {
            Text(String(format: String(localized: "Delete \"%@\"?", bundle: bundle), pendingDeleteModelName))
        }
        .sheet(item: $providerUsageReportContext) { context in
            ProviderUsageReportView(context: context)
                .environment(\.localizationBundle, bundle)
        }
        .sheet(item: $modelUsageReportContext) { context in
            ModelUsageReportView(context: context)
                .environment(\.localizationBundle, bundle)
        }
        .sheet(item: $agentUsageReportContext) { context in
            AgentUsageReportView(context: context)
                .environment(\.localizationBundle, bundle)
        }
        .sheet(isPresented: $showingProviderComparisonReport) {
            UsageComparisonReportView()
                .environment(\.localizationBundle, bundle)
        }
    }

    private var shouldPersistAgentDefaultsOnChange: Bool {
        isApplyingAgentDefaults == false
            && suppressAgentDefaultsPersistence == false
            && section == .agentTask
    }

    @ViewBuilder
    var leftPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch section {
            case .provider:
                entityListPanel {
                    List(selection: $selectedProviderId) {
                        ForEach(
                            sortedProviders.compactMap { provider -> (id: Int64, profile: AgentProviderProfile)? in
                                guard let providerId = provider.id else { return nil }
                                return (id: providerId, profile: provider)
                            },
                            id: \.id
                        ) { item in
                            HStack(spacing: 8) {
                                Text(item.profile.name)
                                Spacer()
                                if item.profile.isDefault {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(item.id as Int64?)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedProviderId = item.id
                            }
                        }
                    }
                    .listStyle(.inset)
                } toolbar: {
                    HStack(spacing: 8) {
                        toolbarIconButton(symbol: "plus", help: String(localized: "Add Provider", bundle: bundle)) {
                            resetProviderForm()
                            focusProviderDisplayNameField()
                        }

                        Divider()
                            .frame(height: 14)

                        toolbarIconButton(symbol: "minus", help: String(localized: "Delete Selected Provider", bundle: bundle), isDisabled: selectedProviderId == nil || selectedProviderIsDefault) {
                            prepareDeleteProvider()
                        }

                        Spacer(minLength: 8)

                        toolbarIconButton(symbol: "checkmark.circle", help: String(localized: "Set as Default", bundle: bundle), isDisabled: selectedProviderId == nil || selectedProviderIsDefault) {
                            Task {
                                await setDefaultProvider()
                            }
                        }

                        toolbarIconButton(symbol: "chart.line.uptrend.xyaxis", help: String(localized: "Usage Statistics", bundle: bundle), isDisabled: providers.isEmpty) {
                            showingProviderComparisonReport = true
                        }
                    }
                }

            case .model:
                entityListPanel {
                    List(selection: $selectedModelId) {
                        ForEach(
                            sortedModels.compactMap { model -> (id: Int64, profile: AgentModelProfile)? in
                                guard let modelId = model.id else { return nil }
                                return (id: modelId, profile: model)
                            },
                            id: \.id
                        ) { item in
                            HStack(spacing: 8) {
                                Text(item.profile.name)
                                Spacer()
                                if item.profile.isDefault {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(item.id as Int64?)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedModelId = item.id
                            }
                        }
                    }
                    .listStyle(.inset)
                } toolbar: {
                    HStack(spacing: 8) {
                        toolbarIconButton(symbol: "plus", help: String(localized: "Add Model", bundle: bundle)) {
                            resetModelForm()
                            focusModelProfileNameField()
                        }

                        Divider()
                            .frame(height: 14)

                        toolbarIconButton(symbol: "minus", help: String(localized: "Delete Selected Model", bundle: bundle), isDisabled: selectedModelId == nil || selectedModelIsDefault) {
                            prepareDeleteModel()
                        }

                        Spacer(minLength: 8)

                        toolbarTextButton(title: "Set as Default", isDisabled: selectedModelId == nil || selectedModelIsDefault) {
                            Task {
                                await setDefaultModel()
                            }
                        }
                    }
                }

            case .agentTask:
                entityListPanel {
                    List(selection: $selectedAgentTask) {
                        Text("Summary", bundle: bundle)
                            .tag(AgentTaskType.summary)
                        Text("Translation", bundle: bundle)
                            .tag(AgentTaskType.translation)
                    }
                    .listStyle(.inset)
                } toolbar: {
                    HStack(spacing: 8) {
                        Text("Built-in agents", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                    }
                }
            }

            Spacer()
        }
    }

    @ViewBuilder
    var rightPane: some View {
        switch section {
        case .provider:
            providerRightPane
        case .model:
            modelRightPane
        case .agentTask:
            agentRightPane
        }
    }
}

enum AgentSettingsSection: Hashable {
    case provider
    case model
    case agentTask
}

struct ProviderUsageReportContext: Identifiable {
    let id: Int64
    let providerName: String
    let isArchived: Bool
}

struct ModelUsageReportContext: Identifiable {
    let id: Int64
    let modelName: String
    let isArchived: Bool
}

struct AgentUsageReportContext: Identifiable {
    let taskType: AgentTaskType

    var id: String {
        taskType.rawValue
    }
}
