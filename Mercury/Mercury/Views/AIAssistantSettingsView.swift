import SwiftUI

struct AIAssistantSettingsView: View {
    enum ProviderFocusField: Hashable {
        case displayName
    }

    enum ModelFocusField: Hashable {
        case profileName
    }

    @EnvironmentObject var appModel: AppModel
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

                        resultSection
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
                        ForEach(sortedProviders) { provider in
                            if let providerId = provider.id {
                                HStack(spacing: 8) {
                                    Text(provider.name)
                                    Spacer()
                                    if provider.isDefault {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tag(providerId as Int64?)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedProviderId = providerId
                                }
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
                        ForEach(sortedModels) { item in
                            if let modelId = item.id {
                                HStack(spacing: 8) {
                                    Text(item.name)
                                    Spacer()
                                    if item.isDefault {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tag(modelId as Int64?)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedModelId = modelId
                                }
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
                    List {
                        Text("Default Agent (coming soon)")
                            .foregroundStyle(.secondary)
                    }
                    .listStyle(.inset)
                } toolbar: {
                    HStack(spacing: 8) {
                        toolbarIconButton(symbol: "plus", help: "Add Agent", isDisabled: true) {}

                        Divider()
                            .frame(height: 14)

                        toolbarIconButton(symbol: "minus", help: "Delete Selected Agent", isDisabled: true) {}

                        Spacer(minLength: 0)
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
