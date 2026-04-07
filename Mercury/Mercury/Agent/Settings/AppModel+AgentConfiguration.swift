import Foundation

struct AgentAvailabilitySnapshot: Sendable, Equatable {
    let summary: Bool
    let translation: Bool
    let tagging: Bool
}

struct AgentConfigurationSnapshot: Sendable {
    let providers: [AgentProviderProfile]
    let models: [AgentModelProfile]
    let summaryDefaults: SummaryAgentDefaults
    let translationDefaults: TranslationAgentDefaults
    let taggingDefaults: TaggingAgentDefaults
    let availability: AgentAvailabilitySnapshot
}

extension AppModel {
    func loadAgentConfigurationSnapshot() async throws -> AgentConfigurationSnapshot {
        if let agentConfigurationSnapshot {
            return agentConfigurationSnapshot
        }
        return try await refreshAgentConfigurationSnapshot()
    }

    func loadAgentConfigurationSnapshotIfAvailable() async -> AgentConfigurationSnapshot? {
        do {
            return try await loadAgentConfigurationSnapshot()
        } catch {
            invalidateAgentConfigurationSnapshot()
            return nil
        }
    }

    func loadEffectiveSummaryAgentDefaults() async -> SummaryAgentDefaults {
        if let snapshot = await loadAgentConfigurationSnapshotIfAvailable() {
            return snapshot.summaryDefaults
        }
        return loadSummaryAgentDefaults()
    }

    func loadEffectiveTranslationAgentDefaults() async -> TranslationAgentDefaults {
        if let snapshot = await loadAgentConfigurationSnapshotIfAvailable() {
            return snapshot.translationDefaults
        }
        return loadTranslationAgentDefaults()
    }

    func loadEffectiveTaggingAgentDefaults() async -> TaggingAgentDefaults {
        if let snapshot = await loadAgentConfigurationSnapshotIfAvailable() {
            return snapshot.taggingDefaults
        }
        return loadTaggingAgentDefaults()
    }

    @discardableResult
    func refreshAgentConfigurationSnapshot() async throws -> AgentConfigurationSnapshot {
        let providers = try await loadAgentProviderProfiles()
        let models = try await loadAgentModelProfiles()

        let rawSummaryDefaults = loadSummaryAgentDefaults()
        let rawTranslationDefaults = loadTranslationAgentDefaults()
        let rawTaggingDefaults = loadTaggingAgentDefaults()

        let summaryDefaults = normalizedSummaryAgentDefaults(rawSummaryDefaults, models: models)
        let translationDefaults = normalizedTranslationAgentDefaults(rawTranslationDefaults, models: models)
        let taggingDefaults = normalizedTaggingAgentDefaults(rawTaggingDefaults, models: models)

        if summaryDefaults != rawSummaryDefaults {
            storeSummaryAgentDefaults(
                summaryDefaults,
                postChangeNotification: false,
                scheduleConfigurationRefresh: false
            )
        }
        if translationDefaults != rawTranslationDefaults {
            storeTranslationAgentDefaults(
                translationDefaults,
                postChangeNotification: false,
                scheduleConfigurationRefresh: false
            )
        }
        if taggingDefaults != rawTaggingDefaults {
            storeTaggingAgentDefaults(
                taggingDefaults,
                postChangeNotification: false,
                scheduleConfigurationRefresh: false
            )
        }

        let availability = makeAgentAvailabilitySnapshot(
            providers: providers,
            models: models,
            summaryDefaults: summaryDefaults,
            translationDefaults: translationDefaults,
            taggingDefaults: taggingDefaults
        )

        let snapshot = AgentConfigurationSnapshot(
            providers: providers,
            models: models,
            summaryDefaults: summaryDefaults,
            translationDefaults: translationDefaults,
            taggingDefaults: taggingDefaults,
            availability: availability
        )

        agentConfigurationSnapshot = snapshot
        isSummaryAgentAvailable = availability.summary
        isTranslationAgentAvailable = availability.translation
        isTaggingAgentAvailable = availability.tagging
        return snapshot
    }

    func refreshAgentConfigurationSnapshotSafely() async {
        do {
            _ = try await refreshAgentConfigurationSnapshot()
        } catch {
            invalidateAgentConfigurationSnapshot()
        }
    }

    private func invalidateAgentConfigurationSnapshot() {
        agentConfigurationSnapshot = nil
        isSummaryAgentAvailable = false
        isTranslationAgentAvailable = false
        isTaggingAgentAvailable = false
    }

    private func normalizedSummaryAgentDefaults(
        _ defaults: SummaryAgentDefaults,
        models: [AgentModelProfile]
    ) -> SummaryAgentDefaults {
        let normalizedRoute = normalizedRouteModelSelection(
            primaryModelId: defaults.primaryModelId,
            fallbackModelId: defaults.fallbackModelId,
            models: models
        )
        return SummaryAgentDefaults(
            targetLanguage: defaults.targetLanguage,
            detailLevel: defaults.detailLevel,
            primaryModelId: normalizedRoute.primaryModelId,
            fallbackModelId: normalizedRoute.fallbackModelId
        )
    }

    private func normalizedTranslationAgentDefaults(
        _ defaults: TranslationAgentDefaults,
        models: [AgentModelProfile]
    ) -> TranslationAgentDefaults {
        let normalizedRoute = normalizedRouteModelSelection(
            primaryModelId: defaults.primaryModelId,
            fallbackModelId: defaults.fallbackModelId,
            models: models
        )
        return TranslationAgentDefaults(
            targetLanguage: defaults.targetLanguage,
            primaryModelId: normalizedRoute.primaryModelId,
            fallbackModelId: normalizedRoute.fallbackModelId,
            promptStrategy: defaults.promptStrategy,
            concurrencyDegree: defaults.concurrencyDegree
        )
    }

    private func normalizedTaggingAgentDefaults(
        _ defaults: TaggingAgentDefaults,
        models: [AgentModelProfile]
    ) -> TaggingAgentDefaults {
        let normalizedRoute = normalizedRouteModelSelection(
            primaryModelId: defaults.primaryModelId,
            fallbackModelId: defaults.fallbackModelId,
            models: models
        )
        return TaggingAgentDefaults(
            primaryModelId: normalizedRoute.primaryModelId,
            fallbackModelId: normalizedRoute.fallbackModelId
        )
    }

    private func normalizedRouteModelSelection(
        primaryModelId: Int64?,
        fallbackModelId: Int64?,
        models: [AgentModelProfile]
    ) -> (primaryModelId: Int64?, fallbackModelId: Int64?) {
        let validModelIDs = Set(models.compactMap(\.id))

        let normalizedPrimaryModelId: Int64?
        if let primaryModelId,
           validModelIDs.contains(primaryModelId) {
            normalizedPrimaryModelId = primaryModelId
        } else {
            normalizedPrimaryModelId = nil
        }

        let normalizedFallbackModelId: Int64?
        if let fallbackModelId,
           validModelIDs.contains(fallbackModelId),
           fallbackModelId != normalizedPrimaryModelId {
            normalizedFallbackModelId = fallbackModelId
        } else {
            normalizedFallbackModelId = nil
        }

        return (normalizedPrimaryModelId, normalizedFallbackModelId)
    }
}