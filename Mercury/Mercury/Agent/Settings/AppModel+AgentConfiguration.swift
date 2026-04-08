import Foundation

struct AgentAvailabilitySnapshot: Sendable, Equatable {
    let summary: Bool
    let translation: Bool
    let tagging: Bool
}

struct AgentConfigurationSnapshot: Sendable {
    let providers: [AgentProviderProfile]
    let models: [AgentModelProfile]
    let summaryProfile: AgentProfile
    let translationProfile: AgentProfile
    let taggingProfile: AgentProfile
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
        return (try? await loadSummaryAgentDefaults()) ?? summaryAgentDefaults(profile: nil)
    }

    func loadEffectiveTranslationAgentDefaults() async -> TranslationAgentDefaults {
        if let snapshot = await loadAgentConfigurationSnapshotIfAvailable() {
            return snapshot.translationDefaults
        }
        return (try? await loadTranslationAgentDefaults()) ?? translationAgentDefaults(profile: nil)
    }

    func loadEffectiveTaggingAgentDefaults() async -> TaggingAgentDefaults {
        if let snapshot = await loadAgentConfigurationSnapshotIfAvailable() {
            return snapshot.taggingDefaults
        }
        return (try? await loadTaggingAgentDefaults()) ?? taggingAgentDefaults(profile: nil)
    }

    @discardableResult
    func refreshAgentConfigurationSnapshot() async throws -> AgentConfigurationSnapshot {
        let providers = try await loadAgentProviderProfiles()
        let models = try await loadAgentModelProfiles()
        let profilesByType = try await loadAgentProfilesEnsuringBootstrap()
        let summaryProfile = try requiredAgentProfile(.summary, from: profilesByType)
        let translationProfile = try requiredAgentProfile(.translation, from: profilesByType)
        let taggingProfile = try requiredAgentProfile(.tagging, from: profilesByType)

        let rawSummaryDefaults = summaryAgentDefaults(profile: summaryProfile)
        let rawTranslationDefaults = translationAgentDefaults(profile: translationProfile)
        let rawTaggingDefaults = taggingAgentDefaults(profile: taggingProfile)

        let summaryDefaults = normalizedSummaryAgentDefaults(rawSummaryDefaults, models: models)
        let translationDefaults = normalizedTranslationAgentDefaults(rawTranslationDefaults, models: models)
        let taggingDefaults = normalizedTaggingAgentDefaults(rawTaggingDefaults, models: models)
        // Snapshot refresh is a read-only flow. Normalize persisted selections
        // in memory for runtime availability and routing, but never mutate
        // stored agent profiles or feature-specific defaults here.

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
            summaryProfile: summaryProfile,
            translationProfile: translationProfile,
            taggingProfile: taggingProfile,
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

    private func requiredAgentProfile(
        _ agentType: AgentType,
        from profilesByType: [AgentType: AgentProfile]
    ) throws -> AgentProfile {
        guard let profile = profilesByType[agentType] else {
            throw AgentSettingsError.agentProfileNotFound
        }
        return profile
    }
}
