import SwiftUI

struct AIAssistantSettingsView: View {
    enum ProviderFocusField: Hashable {
        case displayName
    }

    enum ModelFocusField: Hashable {
        case profileName
    }

    @EnvironmentObject var appModel: AppModel
    @AppStorage("AI.Summary.AutoSummaryEnableWarning") var summaryAutoEnableWarning: Bool = true
    @State var section: AISettingsSection = .provider

    @State var providers: [AIProviderProfile] = []
    @State var selectedProviderId: Int64?
    @State var providerName: String = ""
    @State var providerBaseURL: String = "http://localhost:5810/v1"
    @State var providerAPIKey: String = ""
    @State var providerHasStoredAPIKey: Bool = false
    @State var providerEnabled: Bool = true
    @State var providerTestModel: String = "qwen3"
    @State var isProviderTesting: Bool = false

    @State var models: [AIModelProfile] = []
    @State var selectedModelId: Int64?
    @State var modelProviderId: Int64?
    @State var modelProfileName: String = ""
    @State var modelName: String = "qwen3"
    @State var modelShowAdvancedParameters: Bool = false
    @State var modelStreaming: Bool = true
    @State var modelTemperature: String = ""
    @State var modelTopP: String = ""
    @State var modelMaxTokens: String = ""
    @State var modelTestSystemMessage: String = "You are a concise assistant."
    @State var modelTestUserMessage: String = "Reply with exactly: ok"
    @State var isModelTesting: Bool = false

    @State var selectedAgentTask: AITaskType = .summary
    @State var summaryPrimaryModelId: Int64?
    @State var summaryFallbackModelId: Int64?
    @State var translationPrimaryModelId: Int64?
    @State var translationFallbackModelId: Int64?
    @State var summaryDefaultTargetLanguage: String = "en"
    @State var translationDefaultTargetLanguage: String = "en"
    @State var summaryDefaultDetailLevel: AISummaryDetailLevel = .medium

    @State var statusText: String = "Ready"
    @State var outputPreview: String = ""
    @State var latencyMs: Int?
    @State var pendingDeleteProviderId: Int64?
    @State var pendingDeleteProviderName: String = ""
    @State var showingProviderDeleteConfirm: Bool = false
    @State var pendingDeleteModelId: Int64?
    @State var pendingDeleteModelName: String = ""
    @State var showingModelDeleteConfirm: Bool = false
    @FocusState var providerFocusedField: ProviderFocusField?
    @FocusState var modelFocusedField: ModelFocusField?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Picker("", selection: $section) {
                    Text("Providers").tag(AISettingsSection.provider)
                    Text("Models").tag(AISettingsSection.model)
                    Text("Agents").tag(AISettingsSection.agentTask)
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
            await loadAISettingsData()
        }
        .onChange(of: summaryPrimaryModelId) { _, _ in
            persistSummaryAgentDefaults()
        }
        .onChange(of: summaryFallbackModelId) { _, _ in
            persistSummaryAgentDefaults()
        }
        .onChange(of: summaryDefaultTargetLanguage) { _, _ in
            persistSummaryAgentDefaults()
        }
        .onChange(of: summaryDefaultDetailLevel) { _, _ in
            persistSummaryAgentDefaults()
        }
        .onChange(of: translationPrimaryModelId) { _, _ in
            persistTranslationAgentDefaults()
        }
        .onChange(of: translationFallbackModelId) { _, _ in
            persistTranslationAgentDefaults()
        }
        .onChange(of: translationDefaultTargetLanguage) { _, _ in
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
            "Delete Provider",
            isPresented: $showingProviderDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await deleteProvider()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete provider \"\(pendingDeleteProviderName)\"? Models using this provider will be reassigned to the system default provider.")
        }
        .confirmationDialog(
            "Delete Model",
            isPresented: $showingModelDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await deleteModel()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete model \"\(pendingDeleteModelName)\"?")
        }
    }

    @ViewBuilder
    var leftPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch section {
            case .provider:
                entityListPanel {
                    List(selection: $selectedProviderId) {
                        ForEach(
                            sortedProviders.compactMap { provider -> (id: Int64, profile: AIProviderProfile)? in
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
                        toolbarIconButton(symbol: "plus", help: "Add Provider") {
                            resetProviderForm()
                            focusProviderDisplayNameField()
                        }

                        Divider()
                            .frame(height: 14)

                        toolbarIconButton(symbol: "minus", help: "Delete Selected Provider", isDisabled: selectedProviderId == nil || selectedProviderIsDefault) {
                            prepareDeleteProvider()
                        }

                        Spacer(minLength: 8)

                        toolbarTextButton(title: "Set as Default", isDisabled: selectedProviderId == nil || selectedProviderIsDefault) {
                            Task {
                                await setDefaultProvider()
                            }
                        }
                    }
                }

            case .model:
                entityListPanel {
                    List(selection: $selectedModelId) {
                        ForEach(
                            sortedModels.compactMap { model -> (id: Int64, profile: AIModelProfile)? in
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
                        toolbarIconButton(symbol: "plus", help: "Add Model") {
                            resetModelForm()
                            focusModelProfileNameField()
                        }

                        Divider()
                            .frame(height: 14)

                        toolbarIconButton(symbol: "minus", help: "Delete Selected Model", isDisabled: selectedModelId == nil || selectedModelIsDefault) {
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
                        Text("Summary")
                            .tag(AITaskType.summary)
                        Text("Translation")
                            .tag(AITaskType.translation)
                    }
                    .listStyle(.inset)
                } toolbar: {
                    HStack(spacing: 8) {
                        Text("Built-in agents")
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

enum AISettingsSection: Hashable {
    case provider
    case model
    case agentTask
}
