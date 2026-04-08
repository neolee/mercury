//
//  AppModel+Agent.swift
//  Mercury
//
//  Created by GitHub Copilot on 2026/2/18.
//

import Foundation
import GRDB

extension Notification.Name {
    static let openDebugIssuesRequested = Notification.Name("Mercury.OpenDebugIssuesRequested")
    static let summaryAgentDefaultsDidChange = Notification.Name("Mercury.SummaryAgentDefaultsDidChange")
    static let summaryRecordsDidChange = Notification.Name("Mercury.SummaryRecordsDidChange")
    static let translationAgentDefaultsDidChange = Notification.Name("Mercury.TranslationAgentDefaultsDidChange")
    static let taggingAgentDefaultsDidChange = Notification.Name("Mercury.TaggingAgentDefaultsDidChange")
}

struct SummaryAgentDefaults: Sendable, Equatable {
    var targetLanguage: String
    var detailLevel: SummaryDetailLevel
    var primaryModelId: Int64?
    var fallbackModelId: Int64?
}

struct TranslationAgentDefaults: Sendable, Equatable {
    var targetLanguage: String
    var primaryModelId: Int64?
    var fallbackModelId: Int64?
    var promptStrategy: TranslationPromptStrategy
    var concurrencyDegree: Int
}

struct TaggingAgentDefaults: Sendable, Equatable {
    var primaryModelId: Int64?
    var fallbackModelId: Int64?
}

private struct AgentRouteSelection: Sendable, Equatable {
    var primaryModelId: Int64? = nil
    var fallbackModelId: Int64? = nil
}

private enum LegacyAgentRouteSettingsKey {
    static let summaryPrimaryModelId = "Agent.Summary.PrimaryModelId"
    static let summaryFallbackModelId = "Agent.Summary.FallbackModelId"
    static let translationPrimaryModelId = TranslationSettingsKey.primaryModelId
    static let translationFallbackModelId = TranslationSettingsKey.fallbackModelId
    static let taggingPrimaryModelId = "Agent.Tagging.PrimaryModelId"
    static let taggingFallbackModelId = "Agent.Tagging.FallbackModelId"
}

enum AgentSettingsError: LocalizedError {
    case providerNameRequired
    case modelProfileNameRequired
    case providerNotFound
    case modelNotFound
    case agentProfileNotFound
    case providerAPIKeyMissing
    case cannotDeleteDefaultProvider
    case cannotDeleteDefaultModel
    case noDefaultProviderAvailable

    var errorDescription: String? {
        switch self {
        case .providerNameRequired:
            return "Provider name is required."
        case .modelProfileNameRequired:
            return "Model profile name is required."
        case .providerNotFound:
            return "Provider profile was not found."
        case .modelNotFound:
            return "Model profile was not found."
        case .agentProfileNotFound:
            return "Agent profile was not found."
        case .providerAPIKeyMissing:
            return "API key is required for a new provider profile."
        case .cannotDeleteDefaultProvider:
            return "Default provider cannot be deleted."
        case .cannotDeleteDefaultModel:
            return "Default model cannot be deleted."
        case .noDefaultProviderAvailable:
            return "No default provider is available."
        }
    }
}

extension AppModel {
    private func finalizeAgentDefaultsSave(
        notificationName: Notification.Name
    ) async {
        await refreshAgentConfigurationSnapshotSafely()
        NotificationCenter.default.post(name: notificationName, object: nil)
    }

    private func loadLegacyRouteSelection(
        for agentType: AgentType,
        defaults: UserDefaults
    ) -> AgentRouteSelection {
        let primaryKey: String
        let fallbackKey: String

        switch agentType {
        case .summary:
            primaryKey = LegacyAgentRouteSettingsKey.summaryPrimaryModelId
            fallbackKey = LegacyAgentRouteSettingsKey.summaryFallbackModelId
        case .translation:
            primaryKey = LegacyAgentRouteSettingsKey.translationPrimaryModelId
            fallbackKey = LegacyAgentRouteSettingsKey.translationFallbackModelId
        case .tagging:
            primaryKey = LegacyAgentRouteSettingsKey.taggingPrimaryModelId
            fallbackKey = LegacyAgentRouteSettingsKey.taggingFallbackModelId
        }

        return AgentRouteSelection(
            primaryModelId: (defaults.object(forKey: primaryKey) as? NSNumber)?.int64Value,
            fallbackModelId: (defaults.object(forKey: fallbackKey) as? NSNumber)?.int64Value
        )
    }

    private func normalizedPersistedRouteSelection(
        primaryModelId: Int64?,
        fallbackModelId: Int64?,
        validModelIDs: Set<Int64>
    ) -> AgentRouteSelection {
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

        return AgentRouteSelection(
            primaryModelId: normalizedPrimaryModelId,
            fallbackModelId: normalizedFallbackModelId
        )
    }

    private func loadSummaryFeatureSettings(
        defaults: UserDefaults
    ) -> (targetLanguage: String, detailLevel: SummaryDetailLevel) {
        let targetLanguage = AgentLanguageOption.normalizeCode(
            defaults.string(forKey: "Agent.Summary.DefaultTargetLanguage") ?? AgentLanguageOption.english.code
        )
        let detailRaw = defaults.string(forKey: "Agent.Summary.DefaultDetailLevel") ?? SummaryDetailLevel.medium.rawValue
        let detailLevel = SummaryDetailLevel(rawValue: detailRaw) ?? .medium
        return (targetLanguage, detailLevel)
    }

    private func loadTranslationFeatureSettings(
        defaults: UserDefaults
    ) -> (targetLanguage: String, promptStrategy: TranslationPromptStrategy, concurrencyDegree: Int) {
        let targetLanguage = AgentLanguageOption.normalizeCode(
            defaults.string(forKey: TranslationSettingsKey.targetLanguage) ?? AgentLanguageOption.english.code
        )
        let promptStrategy = TranslationPromptStrategy(
            rawValue: defaults.string(forKey: TranslationSettingsKey.promptStrategy) ?? TranslationPromptStrategy.standard.rawValue
        ) ?? .standard
        let hasStoredConcurrency = defaults.object(forKey: TranslationSettingsKey.concurrencyDegree) != nil
        let concurrencyDegree: Int
        if hasStoredConcurrency {
            let storedConcurrency = defaults.integer(forKey: TranslationSettingsKey.concurrencyDegree)
            concurrencyDegree = clampTranslationConcurrencyDegree(storedConcurrency)
        } else {
            concurrencyDegree = TranslationSettingsKey.defaultConcurrencyDegree
        }
        return (targetLanguage, promptStrategy, concurrencyDegree)
    }

    func summaryAgentDefaults(profile: AgentProfile?) -> SummaryAgentDefaults {
        let featureSettings = loadSummaryFeatureSettings(defaults: agentSettingsDefaults)
        return SummaryAgentDefaults(
            targetLanguage: featureSettings.targetLanguage,
            detailLevel: featureSettings.detailLevel,
            primaryModelId: profile?.primaryModelProfileId,
            fallbackModelId: profile?.fallbackModelProfileId
        )
    }

    func translationAgentDefaults(profile: AgentProfile?) -> TranslationAgentDefaults {
        let featureSettings = loadTranslationFeatureSettings(defaults: agentSettingsDefaults)
        return TranslationAgentDefaults(
            targetLanguage: featureSettings.targetLanguage,
            primaryModelId: profile?.primaryModelProfileId,
            fallbackModelId: profile?.fallbackModelProfileId,
            promptStrategy: featureSettings.promptStrategy,
            concurrencyDegree: featureSettings.concurrencyDegree
        )
    }

    func taggingAgentDefaults(profile: AgentProfile?) -> TaggingAgentDefaults {
        TaggingAgentDefaults(
            primaryModelId: profile?.primaryModelProfileId,
            fallbackModelId: profile?.fallbackModelProfileId
        )
    }

    func loadAgentProfilesEnsuringBootstrap() async throws -> [AgentType: AgentProfile] {
        let defaults = agentSettingsDefaults
        let legacySelections = Dictionary(uniqueKeysWithValues: AgentType.allCases.map { agentType in
            (agentType, loadLegacyRouteSelection(for: agentType, defaults: defaults))
        })

        return try await database.write { db in
            let now = Date()
            let existingModelIDs = Set(try Int64.fetchAll(
                db,
                AgentModelProfile.select(Column("id"))
            ))

            for agentType in AgentType.allCases {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO \(AgentProfile.databaseTableName) (
                            agentType,
                            createdAt,
                            updatedAt
                        ) VALUES (?, ?, ?)
                        """,
                    arguments: [agentType.rawValue, now, now]
                )
            }

            var profilesByType = Dictionary(uniqueKeysWithValues: try AgentProfile.fetchAll(db).map { profile in
                (profile.agentType, profile)
            })

            for agentType in AgentType.allCases {
                guard var profile = profilesByType[agentType] else {
                    continue
                }
                guard profile.primaryModelProfileId == nil,
                      profile.fallbackModelProfileId == nil else {
                    continue
                }

                let legacySelection = legacySelections[agentType] ?? AgentRouteSelection()
                let normalizedSelection = self.normalizedPersistedRouteSelection(
                    primaryModelId: legacySelection.primaryModelId,
                    fallbackModelId: legacySelection.fallbackModelId,
                    validModelIDs: existingModelIDs
                )
                guard normalizedSelection.primaryModelId != nil || normalizedSelection.fallbackModelId != nil else {
                    continue
                }

                profile.primaryModelProfileId = normalizedSelection.primaryModelId
                profile.fallbackModelProfileId = normalizedSelection.fallbackModelId
                profile.updatedAt = now
                try profile.update(db)
                profilesByType[agentType] = profile
            }

            return profilesByType
        }
    }

    func loadAgentProfileEnsuringBootstrap(agentType: AgentType) async throws -> AgentProfile {
        let profilesByType = try await loadAgentProfilesEnsuringBootstrap()
        guard let profile = profilesByType[agentType] else {
            throw AgentSettingsError.agentProfileNotFound
        }
        return profile
    }

    private func saveAgentRouteSelection(
        for agentType: AgentType,
        primaryModelId: Int64?,
        fallbackModelId: Int64?
    ) async throws {
        try await database.write { db in
            let existingModelIDs = Set(try Int64.fetchAll(
                db,
                AgentModelProfile.select(Column("id"))
            ))
            let normalizedSelection = self.normalizedPersistedRouteSelection(
                primaryModelId: primaryModelId,
                fallbackModelId: fallbackModelId,
                validModelIDs: existingModelIDs
            )
            let now = Date()

            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO \(AgentProfile.databaseTableName) (
                        agentType,
                        createdAt,
                        updatedAt
                    ) VALUES (?, ?, ?)
                    """,
                arguments: [agentType.rawValue, now, now]
            )

            guard var profile = try AgentProfile
                .filter(Column("agentType") == agentType.rawValue)
                .fetchOne(db) else {
                throw AgentSettingsError.agentProfileNotFound
            }

            profile.primaryModelProfileId = normalizedSelection.primaryModelId
            profile.fallbackModelProfileId = normalizedSelection.fallbackModelId
            profile.updatedAt = now
            try profile.update(db)
        }
    }

    // MARK: - Summary agent defaults

    func summaryAutoEnableWarningEnabled() -> Bool {
        agentSettingsDefaults.object(forKey: "Agent.Summary.AutoSummaryEnableWarning") as? Bool ?? true
    }

    func setSummaryAutoEnableWarningEnabled(_ enabled: Bool) {
        agentSettingsDefaults.set(enabled, forKey: "Agent.Summary.AutoSummaryEnableWarning")
    }

    func loadSummaryAgentDefaults() async throws -> SummaryAgentDefaults {
        let profile = try await loadAgentProfileEnsuringBootstrap(agentType: .summary)
        return summaryAgentDefaults(profile: profile)
    }

    func saveSummaryAgentDefaults(_ defaultsValue: SummaryAgentDefaults) async throws {
        let defaults = agentSettingsDefaults
        let language = AgentLanguageOption.normalizeCode(defaultsValue.targetLanguage)

        try await saveAgentRouteSelection(
            for: .summary,
            primaryModelId: defaultsValue.primaryModelId,
            fallbackModelId: defaultsValue.fallbackModelId
        )

        defaults.set(language, forKey: "Agent.Summary.DefaultTargetLanguage")
        defaults.set(defaultsValue.detailLevel.rawValue, forKey: "Agent.Summary.DefaultDetailLevel")
        await finalizeAgentDefaultsSave(notificationName: .summaryAgentDefaultsDidChange)
    }

    // MARK: - Translation agent defaults

    func loadTranslationAgentDefaults() async throws -> TranslationAgentDefaults {
        let profile = try await loadAgentProfileEnsuringBootstrap(agentType: .translation)
        return translationAgentDefaults(profile: profile)
    }

    func saveTranslationAgentDefaults(_ defaultsValue: TranslationAgentDefaults) async throws {
        let defaults = agentSettingsDefaults
        let language = AgentLanguageOption.normalizeCode(defaultsValue.targetLanguage)

        try await saveAgentRouteSelection(
            for: .translation,
            primaryModelId: defaultsValue.primaryModelId,
            fallbackModelId: defaultsValue.fallbackModelId
        )

        defaults.set(language, forKey: TranslationSettingsKey.targetLanguage)
        defaults.set(defaultsValue.promptStrategy.rawValue, forKey: TranslationSettingsKey.promptStrategy)
        defaults.set(
            clampTranslationConcurrencyDegree(defaultsValue.concurrencyDegree),
            forKey: TranslationSettingsKey.concurrencyDegree
        )
        await finalizeAgentDefaultsSave(notificationName: .translationAgentDefaultsDidChange)
    }

    private func clampTranslationConcurrencyDegree(_ raw: Int) -> Int {
        return min(
            max(raw, TranslationSettingsKey.concurrencyRange.lowerBound),
            TranslationSettingsKey.concurrencyRange.upperBound
        )
    }

    func requestOpenDebugIssues() {
        NotificationCenter.default.post(name: .openDebugIssuesRequested, object: nil)
    }

    // MARK: - Tagging agent defaults

    func loadTaggingAgentDefaults() async throws -> TaggingAgentDefaults {
        let profile = try await loadAgentProfileEnsuringBootstrap(agentType: .tagging)
        return taggingAgentDefaults(profile: profile)
    }

    func saveTaggingAgentDefaults(_ defaultsValue: TaggingAgentDefaults) async throws {
        try await saveAgentRouteSelection(
            for: .tagging,
            primaryModelId: defaultsValue.primaryModelId,
            fallbackModelId: defaultsValue.fallbackModelId
        )
        await finalizeAgentDefaultsSave(notificationName: .taggingAgentDefaultsDidChange)
    }

}
