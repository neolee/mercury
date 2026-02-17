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

            AIAssistantSettingsView()
                .tabItem {
                    Label("AI Assistant", systemImage: "sparkles")
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

private struct AIAssistantSettingsView: View {
    private enum ProviderFocusField: Hashable {
        case displayName
    }

    @EnvironmentObject private var appModel: AppModel
    @State private var section: AISettingsSection = .provider

    @State private var providers: [AIProviderProfile] = []
    @State private var selectedProviderId: Int64?
    @State private var providerName: String = ""
    @State private var providerBaseURL: String = "http://localhost:5810/v1"
    @State private var providerAPIKey: String = ""
    @State private var providerHasStoredAPIKey: Bool = false
    @State private var providerEnabled: Bool = true
    @State private var providerTestModel: String = "qwen3"
    @State private var isProviderTesting: Bool = false

    @State private var models: [AIModelProfile] = []
    @State private var selectedModelId: Int64?
    @State private var modelProviderId: Int64?
    @State private var modelProfileName: String = ""
    @State private var modelName: String = "qwen3"
    @State private var modelStreaming: Bool = true
    @State private var modelTemperature: String = ""
    @State private var modelTopP: String = ""
    @State private var modelMaxTokens: String = ""
    @State private var modelTestSystemMessage: String = "You are a concise assistant."
    @State private var modelTestUserMessage: String = "Reply with exactly: ok"
    @State private var isModelTesting: Bool = false

    @State private var statusText: String = "Ready"
    @State private var outputPreview: String = ""
    @State private var latencyMs: Int?
    @State private var pendingDeleteProviderId: Int64?
    @State private var pendingDeleteProviderName: String = ""
    @State private var showingProviderDeleteConfirm: Bool = false
    @State private var pendingDeleteModelId: Int64?
    @State private var pendingDeleteModelName: String = ""
    @State private var showingModelDeleteConfirm: Bool = false
    @FocusState private var providerFocusedField: ProviderFocusField?

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
            providerName = provider.name
            providerBaseURL = provider.baseURL
            providerEnabled = provider.isEnabled
            providerTestModel = provider.testModel
            providerAPIKey = ""
            providerHasStoredAPIKey = appModel.hasStoredAIProviderAPIKey(ref: provider.apiKeyRef)
        }
        .onChange(of: selectedModelId) { _, newValue in
            guard let model = models.first(where: { $0.id == newValue }) else { return }
            modelProviderId = model.providerProfileId
            modelProfileName = model.name
            modelName = model.modelName
            modelStreaming = model.isStreaming
            modelTemperature = model.temperature.map { String($0) } ?? ""
            modelTopP = model.topP.map { String($0) } ?? ""
            modelMaxTokens = model.maxTokens.map { String($0) } ?? ""
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
    private var leftPane: some View {
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
                        ForEach(models) { item in
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
    private var rightPane: some View {
        switch section {
        case .provider:
            providerRightPane
        case .model:
            modelRightPane
        case .agentTask:
            agentRightPane
        }
    }

    @ViewBuilder
    private var providerRightPane: some View {
        Text("Properties")
            .font(.headline)

        propertiesCard {
            settingsRow("Display Name") {
                TextField("", text: $providerName)
                    .focused($providerFocusedField, equals: .displayName)
                    .textFieldStyle(.roundedBorder)
            }

            settingsRow("Base URL") {
                TextField("", text: $providerBaseURL)
                    .textFieldStyle(.roundedBorder)
            }

            settingsRow("API Key") {
                SecureField("", text: $providerAPIKey, prompt: Text(providerAPIKeyPrompt))
                    .textFieldStyle(.roundedBorder)
            }

            settingsRow("Test Model") {
                TextField("", text: $providerTestModel)
                    .textFieldStyle(.roundedBorder)
            }

            settingsRow("Enabled") {
                Toggle("", isOn: $providerEnabled)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }

        HStack(spacing: 10) {
            Button("Save") {
                Task {
                    await saveProvider()
                }
            }

            Button("Reset") {
                if selectedProviderId == nil {
                    resetProviderForm()
                } else if let selectedProviderId,
                          let provider = providers.first(where: { $0.id == selectedProviderId }) {
                    providerName = provider.name
                    providerBaseURL = provider.baseURL
                    providerEnabled = provider.isEnabled
                    providerTestModel = provider.testModel
                    providerAPIKey = ""
                    providerHasStoredAPIKey = appModel.hasStoredAIProviderAPIKey(ref: provider.apiKeyRef)
                }
            }

            Button {
                Task {
                    await testProviderConnection()
                }
            } label: {
                if isProviderTesting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Test")
                }
            }
            .disabled(isProviderTesting)

            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

    }

    @ViewBuilder
    private var modelRightPane: some View {
        Text("Properties")
            .font(.headline)

        propertiesCard {
            settingsRow("Provider") {
                Picker("", selection: $modelProviderId) {
                    ForEach(sortedProviders) { provider in
                        Text(provider.name).tag(Optional(provider.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            settingsRow("Profile Name") {
                TextField("", text: $modelProfileName)
                    .textFieldStyle(.roundedBorder)
            }

            settingsRow("Model Name") {
                TextField("", text: $modelName)
                    .textFieldStyle(.roundedBorder)
            }

            settingsRow("Streaming") {
                Toggle("", isOn: $modelStreaming)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            settingsRow("Temperature") {
                TextField("", text: $modelTemperature)
                    .textFieldStyle(.roundedBorder)
            }

            settingsRow("Top-P") {
                TextField("", text: $modelTopP)
                    .textFieldStyle(.roundedBorder)
            }

            settingsRow("Max Tokens") {
                TextField("", text: $modelMaxTokens)
                    .textFieldStyle(.roundedBorder)
            }
        }

        Text("Model Test")
            .font(.headline)

        propertiesCard {
            settingsRow("System Message") {
                TextField("", text: $modelTestSystemMessage, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
            }

            settingsRow("User Message") {
                TextField("", text: $modelTestUserMessage, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
            }
        }

        HStack(spacing: 10) {
            Button("Save") {
                Task {
                    await saveModel()
                }
            }

            Button("Reset") {
                if selectedModelId == nil {
                    resetModelForm()
                } else if let selectedModelId,
                          let model = models.first(where: { $0.id == selectedModelId }) {
                    modelProviderId = model.providerProfileId
                    modelProfileName = model.name
                    modelName = model.modelName
                    modelStreaming = model.isStreaming
                    modelTemperature = model.temperature.map { String($0) } ?? ""
                    modelTopP = model.topP.map { String($0) } ?? ""
                    modelMaxTokens = model.maxTokens.map { String($0) } ?? ""
                }
            }

            Button {
                Task {
                    await testModelChat()
                }
            } label: {
                if isModelTesting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Test")
                }
            }
            .disabled(isModelTesting)

            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var agentRightPane: some View {
        Text("Properties")
            .font(.headline)

        propertiesCard {
            settingsRow("Status") {
                Text("Agent/Task routing will be implemented in the next step.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        HStack(spacing: 10) {
            Button("Save") {}
                .disabled(true)

            Button("Reset") {}
                .disabled(true)

            Button("Test") {}
                .disabled(true)

            Text("Agent/Task not implemented yet")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var providerAPIKeyPrompt: String {
        if providerAPIKey.isEmpty, providerHasStoredAPIKey {
            return String(repeating: "•", count: 12)
        }
        return ""
    }

    @ViewBuilder
    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Result")
                .font(.headline)

            if let latencyMs {
                Text("Latency: \(latencyMs) ms")
                    .foregroundStyle(.secondary)
            }

            if outputPreview.isEmpty {
                Text("No output yet")
                    .foregroundStyle(.secondary)
            } else {
                Text(outputPreview)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func entityListPanel<ListContent: View, ToolbarContent: View>(
        @ViewBuilder list: () -> ListContent,
        @ViewBuilder toolbar: () -> ToolbarContent
    ) -> some View {
        VStack(spacing: 0) {
            list()
                .frame(minHeight: 220)

            Divider()

            HStack(spacing: 0) {
                toolbar()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
            .padding(.horizontal, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func propertiesCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func settingsRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .frame(width: 220, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func toolbarIconButton(
        symbol: String,
        help: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
                .background(Color.clear)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(help)
        .disabled(isDisabled)
        .foregroundStyle(isDisabled ? .secondary : .primary)
    }

    @ViewBuilder
    private func toolbarTextButton(
        title: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(isDisabled ? .secondary : .primary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.6)
            )
            .disabled(isDisabled)
    }

    private var sortedProviders: [AIProviderProfile] {
        providers.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault && !rhs.isDefault
            }

            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }

            return lhs.updatedAt > rhs.updatedAt
        }
    }

    @MainActor
    private func testProviderConnection() async {
        let savedProvider = await saveProvider(showSuccessStatus: false)
        guard savedProvider != nil else {
            statusText = "Failed"
            return
        }

        isProviderTesting = true
        statusText = "Testing..."
        outputPreview = ""
        latencyMs = nil

        do {
            let result: AIProviderConnectionTestResult
            if let selectedProviderId,
               let profile = providers.first(where: { $0.id == selectedProviderId }),
               providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = try await appModel.testAIProviderConnection(
                    baseURL: providerBaseURL,
                    apiKeyRef: profile.apiKeyRef,
                    model: providerTestModel,
                    isStreaming: false,
                    timeoutSeconds: 120,
                    systemMessage: "You are a concise assistant.",
                    userMessage: "Reply with exactly: ok"
                )
            } else {
                result = try await appModel.testAIProviderConnection(
                    baseURL: providerBaseURL,
                    apiKey: providerAPIKey,
                    model: providerTestModel,
                    isStreaming: false,
                    timeoutSeconds: 120,
                    systemMessage: "You are a concise assistant.",
                    userMessage: "Reply with exactly: ok"
                )
            }

            statusText = "Success"
            outputPreview = result.outputPreview.isEmpty ? "(empty response)" : result.outputPreview
            latencyMs = result.latencyMs
        } catch {
            statusText = "Failed"
            outputPreview = error.localizedDescription
        }

        isProviderTesting = false
    }

    @MainActor
    private func testModelChat() async {
        let savedModel = await saveModel(showSuccessStatus: false)
        guard let selectedModelId = savedModel?.id ?? selectedModelId else {
            statusText = "Failed"
            outputPreview = "Please save a model profile before testing chat."
            return
        }

        isModelTesting = true
        statusText = "Testing..."
        outputPreview = ""
        latencyMs = nil

        do {
            let result = try await appModel.testAIModelProfile(
                modelProfileId: selectedModelId,
                systemMessage: modelTestSystemMessage,
                userMessage: modelTestUserMessage,
                timeoutSeconds: 120
            )
            statusText = "Success"
            outputPreview = result.outputPreview.isEmpty ? "(empty response)" : result.outputPreview
            latencyMs = result.latencyMs
        } catch {
            statusText = "Failed"
            outputPreview = error.localizedDescription
        }

        isModelTesting = false
    }

    @MainActor
    private func loadAISettingsData() async {
        do {
            providers = try await appModel.loadAIProviderProfiles()
            models = try await appModel.loadAIModelProfiles()

            if providers.isEmpty == false, selectedProviderId == nil {
                selectedProviderId = providers.first?.id
            }
            if models.isEmpty == false, selectedModelId == nil {
                selectedModelId = models.first?.id
            }
            if modelProviderId == nil {
                modelProviderId = providers.first?.id
            }
        } catch {
            statusText = "Failed"
            outputPreview = error.localizedDescription
        }
    }

    @MainActor
    private func saveProvider(showSuccessStatus: Bool = true) async -> AIProviderProfile? {
        do {
            let saved = try await appModel.saveAIProviderProfile(
                id: selectedProviderId,
                name: providerName,
                baseURL: providerBaseURL,
                apiKey: providerAPIKey,
                testModel: providerTestModel,
                isEnabled: providerEnabled
            )
            providers = try await appModel.loadAIProviderProfiles()
            selectedProviderId = resolveSavedProviderId(saved: saved, providers: providers)
            if let selectedProviderId,
               let selectedProvider = providers.first(where: { $0.id == selectedProviderId }) {
                providerName = selectedProvider.name
                providerBaseURL = selectedProvider.baseURL
                providerEnabled = selectedProvider.isEnabled
                providerTestModel = selectedProvider.testModel
                providerHasStoredAPIKey = appModel.hasStoredAIProviderAPIKey(ref: selectedProvider.apiKeyRef)
            }
            providerAPIKey = ""
            providerHasStoredAPIKey = appModel.hasStoredAIProviderAPIKey(ref: saved.apiKeyRef)
            if showSuccessStatus {
                statusText = "Provider saved"
            }
            return saved
        } catch {
            statusText = error.localizedDescription
            outputPreview = error.localizedDescription
            return nil
        }
    }

    @MainActor
    private func deleteProvider() async {
        guard let selectedId = pendingDeleteProviderId else {
            statusText = "Please select a provider first"
            outputPreview = "Please select a provider first"
            return
        }
        do {
            try await appModel.deleteAIProviderProfile(id: selectedId)
            providers = try await appModel.loadAIProviderProfiles()
            models = try await appModel.loadAIModelProfiles()
            resetProviderForm()
            selectedProviderId = providers.first?.id
            pendingDeleteProviderId = nil
            pendingDeleteProviderName = ""
            statusText = "Provider deleted"
        } catch {
            statusText = error.localizedDescription
            outputPreview = error.localizedDescription
        }
    }

    @MainActor
    private func saveModel(showSuccessStatus: Bool = true) async -> AIModelProfile? {
        guard let selectedModelProviderId = modelProviderId else {
            statusText = "Failed"
            outputPreview = "Please select a provider for this model."
            return nil
        }
        do {
            let saved = try await appModel.saveAIModelProfile(
                id: selectedModelId,
                providerProfileId: selectedModelProviderId,
                name: modelProfileName,
                modelName: modelName,
                isStreaming: modelStreaming,
                temperature: parseOptionalDouble(modelTemperature),
                topP: parseOptionalDouble(modelTopP),
                maxTokens: parseOptionalInt(modelMaxTokens)
            )
            models = try await appModel.loadAIModelProfiles()
            selectedModelId = resolveSavedModelId(saved: saved, models: models)
            if let selectedModelId,
               let selectedModel = models.first(where: { $0.id == selectedModelId }) {
                modelProviderId = selectedModel.providerProfileId
                modelProfileName = selectedModel.name
                modelName = selectedModel.modelName
                modelStreaming = selectedModel.isStreaming
                modelTemperature = selectedModel.temperature.map { String($0) } ?? ""
                modelTopP = selectedModel.topP.map { String($0) } ?? ""
                modelMaxTokens = selectedModel.maxTokens.map { String($0) } ?? ""
            }
            if showSuccessStatus {
                statusText = "Model saved"
            }
            return saved
        } catch {
            statusText = error.localizedDescription
            outputPreview = error.localizedDescription
            return nil
        }
    }

    private func resolveSavedProviderId(saved: AIProviderProfile, providers: [AIProviderProfile]) -> Int64? {
        if let savedId = saved.id,
           providers.contains(where: { $0.id == savedId }) {
            return savedId
        }

        return providers
            .filter {
                $0.name == saved.name &&
                $0.baseURL == saved.baseURL &&
                $0.testModel == saved.testModel
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first?
            .id
    }

    private func resolveSavedModelId(saved: AIModelProfile, models: [AIModelProfile]) -> Int64? {
        if let savedId = saved.id,
           models.contains(where: { $0.id == savedId }) {
            return savedId
        }

        return models
            .filter {
                $0.providerProfileId == saved.providerProfileId &&
                $0.name == saved.name &&
                $0.modelName == saved.modelName
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first?
            .id
    }

    @MainActor
    private func deleteModel() async {
        guard let selectedId = pendingDeleteModelId else {
            statusText = "Please select a model first"
            outputPreview = "Please select a model first"
            return
        }
        do {
            try await appModel.deleteAIModelProfile(id: selectedId)
            models = try await appModel.loadAIModelProfiles()
            resetModelForm()
            selectedModelId = models.first?.id
            pendingDeleteModelId = nil
            pendingDeleteModelName = ""
            statusText = "Model deleted"
        } catch {
            statusText = error.localizedDescription
            outputPreview = error.localizedDescription
        }
    }

    @MainActor
    private func setDefaultProvider() async {
        guard let selectedProviderId else {
            statusText = "Please select a provider first"
            outputPreview = "Please select a provider first"
            return
        }

        do {
            try await appModel.setDefaultAIProviderProfile(id: selectedProviderId)
            providers = try await appModel.loadAIProviderProfiles()
            models = try await appModel.loadAIModelProfiles()
            statusText = "Default provider updated"
        } catch {
            statusText = error.localizedDescription
            outputPreview = error.localizedDescription
        }
    }

    @MainActor
    private func setDefaultModel() async {
        guard let selectedModelId else {
            statusText = "Please select a model first"
            outputPreview = "Please select a model first"
            return
        }

        do {
            try await appModel.setDefaultAIModelProfile(id: selectedModelId)
            models = try await appModel.loadAIModelProfiles()
            statusText = "Default model updated"
        } catch {
            statusText = error.localizedDescription
            outputPreview = error.localizedDescription
        }
    }

    private func prepareDeleteProvider() {
        guard let selectedProviderId,
              let provider = providers.first(where: { $0.id == selectedProviderId }) else {
            statusText = "Please select a provider first"
            return
        }
        guard provider.isDefault == false else {
            statusText = "Default provider cannot be deleted"
            return
        }
        pendingDeleteProviderId = provider.id
        pendingDeleteProviderName = provider.name
        showingProviderDeleteConfirm = true
    }

    private func prepareDeleteModel() {
        guard let selectedModelId,
              let model = models.first(where: { $0.id == selectedModelId }) else {
            statusText = "Please select a model first"
            return
        }
        guard model.isDefault == false else {
            statusText = "Default model cannot be deleted"
            return
        }
        pendingDeleteModelId = model.id
        pendingDeleteModelName = model.name
        showingModelDeleteConfirm = true
    }

    private var selectedProviderIsDefault: Bool {
        guard let selectedProviderId,
              let provider = providers.first(where: { $0.id == selectedProviderId }) else {
            return false
        }
        return provider.isDefault
    }

    private var selectedModelIsDefault: Bool {
        guard let selectedModelId,
              let model = models.first(where: { $0.id == selectedModelId }) else {
            return false
        }
        return model.isDefault
    }

    private func resetProviderForm() {
        selectedProviderId = nil
        providerName = ""
        providerBaseURL = "http://localhost:5810/v1"
        providerAPIKey = ""
        providerHasStoredAPIKey = false
        providerEnabled = true
        providerTestModel = "qwen3"
    }

    private func focusProviderDisplayNameField() {
        DispatchQueue.main.async {
            providerFocusedField = .displayName
        }
    }

    private func resetModelForm() {
        selectedModelId = nil
        modelProviderId = providers.first?.id
        modelProfileName = ""
        modelName = "qwen3"
        modelStreaming = true
        modelTemperature = ""
        modelTopP = ""
        modelMaxTokens = ""
    }

    private func parseOptionalDouble(_ rawValue: String) -> Double? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        return Double(trimmed)
    }

    private func parseOptionalInt(_ rawValue: String) -> Int? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        return Int(trimmed)
    }
}

private enum AISettingsSection: Hashable {
    case provider
    case model
    case agentTask
}
