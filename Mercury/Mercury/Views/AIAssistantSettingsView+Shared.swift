import SwiftUI

extension AIAssistantSettingsView {
    @ViewBuilder
    var resultSection: some View {
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
    func entityListPanel<ListContent: View, ToolbarContent: View>(
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
    func propertiesCard<Content: View>(
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
    func settingsRow<Content: View>(
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
    func toolbarIconButton(
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
    func toolbarTextButton(
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

    var sortedProviders: [AIProviderProfile] {
        sortByDefaultThenName(
            items: providers,
            isDefault: { $0.isDefault },
            name: { $0.name },
            updatedAt: { $0.updatedAt }
        )
    }

    var sortedModels: [AIModelProfile] {
        sortByDefaultThenName(
            items: models,
            isDefault: { $0.isDefault },
            name: { $0.name },
            updatedAt: { $0.updatedAt }
        )
    }

    @MainActor
    func loadAISettingsData() async {
        do {
            try await reloadProvidersAndModels()

            applySavedSummaryAgentDefaults()
            applySavedTranslationAgentDefaults()

            if providers.isEmpty == false, selectedProviderId == nil {
                selectedProviderId = sortedProviders.first?.id
            }
            if models.isEmpty == false, selectedModelId == nil {
                selectedModelId = sortedModels.first?.id
            }
            normalizeModelProviderSelectionForProviderChange()
            normalizeAgentModelSelections()
            persistSummaryAgentDefaults()
            persistTranslationAgentDefaults()
        } catch {
            applyFailureState(error, status: "Failed")
        }
    }

    func applySavedSummaryAgentDefaults() {
        let defaults = appModel.loadSummaryAgentDefaults()
        summaryDefaultTargetLanguage = defaults.targetLanguage
        summaryDefaultDetailLevel = defaults.detailLevel
        summaryPrimaryModelId = defaults.primaryModelId
        summaryFallbackModelId = defaults.fallbackModelId
    }

    func persistSummaryAgentDefaults() {
        appModel.saveSummaryAgentDefaults(
            SummaryAgentDefaults(
                targetLanguage: summaryDefaultTargetLanguage,
                detailLevel: summaryDefaultDetailLevel,
                primaryModelId: summaryPrimaryModelId,
                fallbackModelId: summaryFallbackModelId
            )
        )
    }

    func applySavedTranslationAgentDefaults() {
        let defaults = appModel.loadTranslationAgentDefaults()
        translationDefaultTargetLanguage = defaults.targetLanguage
        translationPrimaryModelId = defaults.primaryModelId
        translationFallbackModelId = defaults.fallbackModelId
    }

    func persistTranslationAgentDefaults() {
        appModel.saveTranslationAgentDefaults(
            TranslationAgentDefaults(
                targetLanguage: translationDefaultTargetLanguage,
                primaryModelId: translationPrimaryModelId,
                fallbackModelId: translationFallbackModelId
            )
        )
    }

    func sortByDefaultThenName<T>(
        items: [T],
        isDefault: (T) -> Bool,
        name: (T) -> String,
        updatedAt: (T) -> Date
    ) -> [T] {
        items.sorted { lhs, rhs in
            if isDefault(lhs) != isDefault(rhs) {
                return isDefault(lhs) && !isDefault(rhs)
            }

            let nameOrder = name(lhs).localizedCaseInsensitiveCompare(name(rhs))
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }

            return updatedAt(lhs) > updatedAt(rhs)
        }
    }

    @MainActor
    func reloadProviders() async throws {
        providers = try await appModel.loadAIProviderProfiles()
    }

    @MainActor
    func reloadModels() async throws {
        models = try await appModel.loadAIModelProfiles()
        normalizeAgentModelSelections()
    }

    @MainActor
    func reloadProvidersAndModels() async throws {
        try await reloadProviders()
        try await reloadModels()
    }

    func applyFailureState(_ message: String, status: String = "Failed") {
        statusText = status
        outputPreview = message
    }

    func applyFailureState(_ error: Error, status: String? = nil) {
        let message = error.localizedDescription
        statusText = status ?? message
        outputPreview = message
    }

    var defaultModelId: Int64? {
        if let modelId = models.first(where: { $0.isDefault })?.id {
            return modelId
        }
        return models.first?.id
    }

    func normalizeAgentModelSelections() {
        let validModelIds = Set(models.compactMap(\.id))

        if let summaryPrimaryModelId, validModelIds.contains(summaryPrimaryModelId) == false {
            self.summaryPrimaryModelId = nil
        }
        if let summaryFallbackModelId, validModelIds.contains(summaryFallbackModelId) == false {
            self.summaryFallbackModelId = nil
        }
        if let translationPrimaryModelId, validModelIds.contains(translationPrimaryModelId) == false {
            self.translationPrimaryModelId = nil
        }
        if let translationFallbackModelId, validModelIds.contains(translationFallbackModelId) == false {
            self.translationFallbackModelId = nil
        }

        if self.summaryPrimaryModelId == nil {
            self.summaryPrimaryModelId = defaultModelId
        }
        if self.translationPrimaryModelId == nil {
            self.translationPrimaryModelId = defaultModelId
        }
    }
}
