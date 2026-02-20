import SwiftUI

extension AgentAssistantSettingsView {
    @ViewBuilder
    var modelRightPane: some View {
        Text("Properties")
            .font(.headline)

        propertiesCard {
            settingsRow("Provider") {
                Picker("", selection: $modelProviderId) {
                    ForEach(
                        sortedProviders.compactMap { provider -> (id: Int64, name: String)? in
                            guard let providerId = provider.id else { return nil }
                            return (id: providerId, name: provider.name)
                        },
                        id: \.id
                    ) { provider in
                        Text(provider.name).tag(Optional<Int64>.some(provider.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            settingsRow("Profile Name") {
                TextField("", text: $modelProfileName)
                    .focused($modelFocusedField, equals: .profileName)
                    .textFieldStyle(.roundedBorder)
            }

            settingsRow("Model Name") {
                TextField("", text: $modelName)
                    .textFieldStyle(.roundedBorder)
            }

            if modelShowAdvancedParameters {
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
        }

        HStack {
            Spacer(minLength: 0)
            Button(modelShowAdvancedParameters ? "hide" : "show advanced parameters") {
                modelShowAdvancedParameters.toggle()
            }
            .buttonStyle(.plain)
            .font(.footnote)
            .underline()
            .foregroundStyle(.tint)
        }
        .padding(.top, -6)
        .padding(.trailing, 8)

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
                          let selectedModel = models.first(where: { $0.id == selectedModelId }) {
                    applyModelToForm(selectedModel)
                }
            }
        }

        propertiesCard {
            settingsRow("System Message") {
                TextField("", text: $modelTestSystemMessage, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
            }

            settingsRow("Prompt") {
                TextField("", text: $modelTestUserMessage, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
            }
        }

        HStack(spacing: 10) {
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

    @MainActor
    func testModelChat() async {
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
            let result = try await appModel.testAgentModelProfile(
                modelProfileId: selectedModelId,
                systemMessage: modelTestSystemMessage,
                userMessage: modelTestUserMessage,
                timeoutSeconds: 120
            )
            statusText = "Success"
            outputPreview = result.outputPreview.isEmpty ? "(empty response)" : result.outputPreview
            latencyMs = result.latencyMs
        } catch {
            applyFailureState(error, status: "Failed")
        }

        isModelTesting = false
    }

    @MainActor
    func saveModel(showSuccessStatus: Bool = true) async -> AgentModelProfile? {
        guard let selectedModelProviderId = modelProviderId else {
            applyFailureState("Please select a provider for this model.")
            return nil
        }
        do {
            let saved = try await appModel.saveAgentModelProfile(
                id: selectedModelId,
                providerProfileId: selectedModelProviderId,
                name: modelProfileName,
                modelName: modelName,
                isStreaming: modelStreaming,
                temperature: parseOptionalDouble(modelTemperature),
                topP: parseOptionalDouble(modelTopP),
                maxTokens: parseOptionalInt(modelMaxTokens)
            )
            try await reloadModels()
            selectedModelId = resolveSavedModelId(saved: saved, models: models)
            if let selectedModelId,
               let selectedModel = models.first(where: { $0.id == selectedModelId }) {
                applyModelToForm(selectedModel)
            }
            if showSuccessStatus {
                statusText = "Model saved"
            }
            return saved
        } catch {
            applyFailureState(error)
            return nil
        }
    }

    func resolveSavedModelId(saved: AgentModelProfile, models: [AgentModelProfile]) -> Int64? {
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
    func deleteModel() async {
        guard let selectedId = pendingDeleteModelId else {
            applyFailureState("Please select a model first")
            return
        }
        do {
            try await appModel.deleteAgentModelProfile(id: selectedId)
            try await reloadModels()
            resetModelForm()
            selectedModelId = sortedModels.first?.id
            pendingDeleteModelId = nil
            pendingDeleteModelName = ""
            statusText = "Model deleted"
        } catch {
            applyFailureState(error)
        }
    }

    @MainActor
    func setDefaultModel() async {
        guard let selectedModelId else {
            applyFailureState("Please select a model first")
            return
        }

        do {
            try await appModel.setDefaultAgentModelProfile(id: selectedModelId)
            try await reloadModels()
            statusText = "Default model updated"
        } catch {
            applyFailureState(error)
        }
    }

    func prepareDeleteModel() {
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

    var selectedModelIsDefault: Bool {
        guard let selectedModelId,
              let model = models.first(where: { $0.id == selectedModelId }) else {
            return false
        }
        return model.isDefault
    }

    func resetModelForm() {
        selectedModelId = nil
        modelProviderId = defaultProviderId
        modelProfileName = ""
        modelName = "qwen3"
        modelStreaming = true
        modelTemperature = ""
        modelTopP = ""
        modelMaxTokens = ""
    }

    var defaultProviderId: Int64? {
        if let providerId = providers.first(where: { $0.isDefault })?.id {
            return providerId
        }
        return providers.first?.id
    }

    func normalizeModelProviderSelectionForProviderChange() {
        let currentProviderExists = modelProviderId.flatMap { selectedId in
            providers.first(where: { $0.id == selectedId })?.id
        } != nil

        if selectedModelId == nil {
            modelProviderId = defaultProviderId
            return
        }

        if currentProviderExists == false {
            modelProviderId = defaultProviderId
        }
    }

    func focusModelProfileNameField() {
        DispatchQueue.main.async {
            modelFocusedField = .profileName
        }
    }

    func applyModelToForm(_ model: AgentModelProfile) {
        modelProviderId = model.providerProfileId
        modelProfileName = model.name
        modelName = model.modelName
        modelStreaming = model.isStreaming
        modelTemperature = model.temperature.map { String($0) } ?? ""
        modelTopP = model.topP.map { String($0) } ?? ""
        modelMaxTokens = model.maxTokens.map { String($0) } ?? ""
    }

    func parseOptionalDouble(_ rawValue: String) -> Double? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        return Double(trimmed)
    }

    func parseOptionalInt(_ rawValue: String) -> Int? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        return Int(trimmed)
    }
}
