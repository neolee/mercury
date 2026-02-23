import SwiftUI

extension AgentSettingsView {
    @ViewBuilder
    var providerRightPane: some View {
        Text("Properties", bundle: bundle)
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
            Button(action: { Task { await saveProvider() } }) { Text("Save", bundle: bundle) }

            Button(action: {
                if selectedProviderId == nil {
                    resetProviderForm()
                } else if let selectedProviderId,
                          let provider = providers.first(where: { $0.id == selectedProviderId }) {
                    applyProviderToForm(provider)
                }
            }) { Text("Reset", bundle: bundle) }

            Button {
                Task {
                    await testProviderConnection()
                }
            } label: {
                if isProviderTesting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Test", bundle: bundle)
                }
            }
            .disabled(isProviderTesting)

            Text(LocalizedStringKey(statusText), bundle: bundle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

    }

    var providerAPIKeyPrompt: String {
        if providerAPIKey.isEmpty, providerHasStoredAPIKey {
            return String(repeating: "•", count: 12)
        }
        return ""
    }

    @MainActor
    func testProviderConnection() async {
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
            let result: AgentProviderConnectionTestResult
            if let selectedProviderId,
               let profile = providers.first(where: { $0.id == selectedProviderId }),
               providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = try await appModel.testAgentProviderConnection(
                    baseURL: providerBaseURL,
                    apiKeyRef: profile.apiKeyRef,
                    model: providerTestModel,
                    isStreaming: false,
                    timeoutSeconds: 120,
                    systemMessage: "You are a concise agent.",
                    userMessage: "Reply with exactly: ok"
                )
            } else {
                result = try await appModel.testAgentProviderConnection(
                    baseURL: providerBaseURL,
                    apiKey: providerAPIKey,
                    model: providerTestModel,
                    isStreaming: false,
                    timeoutSeconds: 120,
                    systemMessage: "You are a concise agent.",
                    userMessage: "Reply with exactly: ok"
                )
            }

            statusText = "Success"
            outputPreview = result.outputPreview.isEmpty ? "(empty response)" : result.outputPreview
            latencyMs = result.latencyMs
        } catch {
            applyFailureState(error, status: "Failed")
        }

        isProviderTesting = false
    }

    @MainActor
    func saveProvider(showSuccessStatus: Bool = true) async -> AgentProviderProfile? {
        do {
            let saved = try await appModel.saveAgentProviderProfile(
                id: selectedProviderId,
                name: providerName,
                baseURL: providerBaseURL,
                apiKey: providerAPIKey,
                testModel: providerTestModel,
                isEnabled: providerEnabled
            )
            try await reloadProviders()
            selectedProviderId = resolveSavedProviderId(saved: saved, providers: providers)
            if let selectedProviderId,
               let selectedProvider = providers.first(where: { $0.id == selectedProviderId }) {
                applyProviderToForm(selectedProvider)
            }
            normalizeModelProviderSelectionForProviderChange()
            providerAPIKey = ""
            providerHasStoredAPIKey = appModel.hasStoredAgentProviderAPIKey(ref: saved.apiKeyRef)
            if showSuccessStatus {
                statusText = "Provider saved"
            }
            return saved
        } catch {
            applyFailureState(error)
            return nil
        }
    }

    func resolveSavedProviderId(saved: AgentProviderProfile, providers: [AgentProviderProfile]) -> Int64? {
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

    @MainActor
    func deleteProvider() async {
        guard let selectedId = pendingDeleteProviderId else {
            statusText = "Please select a provider first"
            outputPreview = "Please select a provider first"
            return
        }
        do {
            try await appModel.deleteAgentProviderProfile(id: selectedId)
            try await reloadProvidersAndModels()
            resetProviderForm()
            selectedProviderId = sortedProviders.first?.id
            normalizeModelProviderSelectionForProviderChange()
            pendingDeleteProviderId = nil
            pendingDeleteProviderName = ""
            statusText = "Provider deleted"
        } catch {
            applyFailureState(error)
        }
    }

    @MainActor
    func setDefaultProvider() async {
        guard let selectedProviderId else {
            applyFailureState("Please select a provider first")
            return
        }

        do {
            try await appModel.setDefaultAgentProviderProfile(id: selectedProviderId)
            try await reloadProvidersAndModels()
            normalizeModelProviderSelectionForProviderChange()
            statusText = "Default provider updated"
        } catch {
            applyFailureState(error)
        }
    }

    func prepareDeleteProvider() {
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

    var selectedProviderIsDefault: Bool {
        guard let selectedProviderId,
              let provider = providers.first(where: { $0.id == selectedProviderId }) else {
            return false
        }
        return provider.isDefault
    }

    func resetProviderForm() {
        selectedProviderId = nil
        providerName = ""
        providerBaseURL = "http://localhost:5810/v1"
        providerAPIKey = ""
        providerHasStoredAPIKey = false
        providerEnabled = true
        providerTestModel = "modelname"
    }

    func focusProviderDisplayNameField() {
        DispatchQueue.main.async {
            providerFocusedField = .displayName
        }
    }

    func applyProviderToForm(_ provider: AgentProviderProfile) {
        providerName = provider.name
        providerBaseURL = provider.baseURL
        providerEnabled = provider.isEnabled
        providerTestModel = provider.testModel
        providerAPIKey = ""
        providerHasStoredAPIKey = appModel.hasStoredAgentProviderAPIKey(ref: provider.apiKeyRef)
    }
}
