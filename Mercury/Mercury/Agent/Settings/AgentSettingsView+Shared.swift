import SwiftUI

extension AgentSettingsView {
    var resultSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Result", bundle: bundle)
                .font(.headline)

            if let latencyMs {
                Text(String(format: String(localized: "Latency: %lld ms", bundle: bundle), Int64(latencyMs)))
                    .foregroundStyle(.secondary)
            }

            if outputPreview.isEmpty {
                Text("No output yet", bundle: bundle)
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
        _ label: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label, bundle: bundle)
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
        title: LocalizedStringKey,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Text(title, bundle: bundle) }
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

    var sortedProviders: [AgentProviderProfile] {
        sortByDefaultThenName(
            items: providers,
            isDefault: { $0.isDefault },
            name: { $0.name },
            updatedAt: { $0.updatedAt }
        )
    }

    var sortedModels: [AgentModelProfile] {
        sortByDefaultThenName(
            items: models,
            isDefault: { $0.isDefault },
            name: { $0.name },
            updatedAt: { $0.updatedAt }
        )
    }

    @MainActor
    func loadAgentSettingsData() async {
        suppressAgentDefaultsPersistence = true
        isApplyingAgentDefaults = true
        defer {
            isApplyingAgentDefaults = false
            Task { @MainActor in
                await Task.yield()
                suppressAgentDefaultsPersistence = false
            }
        }
        do {
            try await reloadAgentConfigurationSnapshot()

            if providers.isEmpty == false, selectedProviderId == nil {
                selectedProviderId = sortedProviders.first?.id
            }
            if models.isEmpty == false, selectedModelId == nil {
                selectedModelId = sortedModels.first?.id
            }
            normalizeModelProviderSelectionForProviderChange()
        } catch {
            applyFailureState(error)
        }
    }

    func persistSummaryAgentDefaults() {
        let defaults = SummaryAgentDefaults(
            targetLanguage: summaryDefaultTargetLanguage,
            detailLevel: summaryDefaultDetailLevel,
            primaryModelId: summaryPrimaryModelId,
            fallbackModelId: summaryFallbackModelId
        )
        Task { @MainActor in
            do {
                try await appModel.saveSummaryAgentDefaults(defaults)
            } catch {
                applyFailureState(error)
            }
        }
    }

    func persistTranslationAgentDefaults() {
        let defaults = TranslationAgentDefaults(
            targetLanguage: translationDefaultTargetLanguage,
            primaryModelId: translationPrimaryModelId,
            fallbackModelId: translationFallbackModelId,
            promptStrategy: translationPromptStrategy,
            concurrencyDegree: translationConcurrencyDegree
        )
        Task { @MainActor in
            do {
                try await appModel.saveTranslationAgentDefaults(defaults)
            } catch {
                applyFailureState(error)
            }
        }
    }

    func persistTaggingAgentDefaults() {
        let defaults = TaggingAgentDefaults(
            primaryModelId: taggingPrimaryModelId,
            fallbackModelId: taggingFallbackModelId
        )
        Task { @MainActor in
            do {
                try await appModel.saveTaggingAgentDefaults(defaults)
            } catch {
                applyFailureState(error)
            }
        }
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
    func reloadAgentConfigurationSnapshot() async throws {
        let snapshot = try await appModel.refreshAgentConfigurationSnapshot()
        applyAgentConfigurationSnapshot(snapshot)
    }

    func applyAgentConfigurationSnapshot(_ snapshot: AgentConfigurationSnapshot) {
        providers = snapshot.providers
        models = snapshot.models

        summaryDefaultTargetLanguage = snapshot.summaryDefaults.targetLanguage
        summaryDefaultDetailLevel = snapshot.summaryDefaults.detailLevel
        summaryPrimaryModelId = snapshot.summaryDefaults.primaryModelId
        summaryFallbackModelId = snapshot.summaryDefaults.fallbackModelId

        translationDefaultTargetLanguage = snapshot.translationDefaults.targetLanguage
        translationPrimaryModelId = snapshot.translationDefaults.primaryModelId
        translationFallbackModelId = snapshot.translationDefaults.fallbackModelId
        translationPromptStrategy = snapshot.translationDefaults.promptStrategy
        translationConcurrencyDegree = snapshot.translationDefaults.concurrencyDegree

        taggingPrimaryModelId = snapshot.taggingDefaults.primaryModelId
        taggingFallbackModelId = snapshot.taggingDefaults.fallbackModelId
    }

    func applyFailureState(_ message: String, status: String? = nil) {
        statusText = status ?? failedStatusText
        outputPreview = message
    }

    func applyFailureState(_ error: Error, status: String? = nil) {
        let message = error.localizedDescription
        statusText = status ?? failedStatusText
        outputPreview = message
    }

    var failedStatusText: String { String(localized: "Failed", bundle: bundle) }

    func beginTestRun() {
        statusText = String(localized: "Testing...", bundle: bundle)
        outputPreview = ""
        latencyMs = nil
    }

    func applyTestSuccess(outputPreview rawOutput: String, latencyMs ms: Int?) {
        statusText = String(localized: "Success", bundle: bundle)
        outputPreview = rawOutput.isEmpty ? "(empty response)" : rawOutput
        latencyMs = ms
    }

}
