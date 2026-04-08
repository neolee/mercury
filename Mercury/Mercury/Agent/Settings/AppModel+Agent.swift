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

enum AgentSettingsError: LocalizedError {
    case providerNameRequired
    case modelProfileNameRequired
    case providerNotFound
    case modelNotFound
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
    private func setOptionalDefaultsValue(
        _ value: Int64?,
        forKey key: String,
        defaults: UserDefaults = .standard
    ) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func finalizeAgentDefaultsSave(
        notificationName: Notification.Name
    ) {
        NotificationCenter.default.post(name: notificationName, object: nil)
        Task { await refreshAgentConfigurationSnapshotSafely() }
    }

    // MARK: - Summary agent defaults

    func summaryAutoEnableWarningEnabled() -> Bool {
        UserDefaults.standard.object(forKey: "Agent.Summary.AutoSummaryEnableWarning") as? Bool ?? true
    }

    func setSummaryAutoEnableWarningEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "Agent.Summary.AutoSummaryEnableWarning")
    }

    func loadSummaryAgentDefaults() -> SummaryAgentDefaults {
        let defaults = UserDefaults.standard
        let language = AgentLanguageOption.normalizeCode(
            defaults.string(forKey: "Agent.Summary.DefaultTargetLanguage") ?? AgentLanguageOption.english.code
        )
        let detailRaw = defaults.string(forKey: "Agent.Summary.DefaultDetailLevel") ?? SummaryDetailLevel.medium.rawValue
        let detail = SummaryDetailLevel(rawValue: detailRaw) ?? .medium
        let primaryModelId = (defaults.object(forKey: "Agent.Summary.PrimaryModelId") as? NSNumber)?.int64Value
        let fallbackModelId = (defaults.object(forKey: "Agent.Summary.FallbackModelId") as? NSNumber)?.int64Value

        return SummaryAgentDefaults(
            targetLanguage: language,
            detailLevel: detail,
            primaryModelId: primaryModelId,
            fallbackModelId: fallbackModelId
        )
    }

    func saveSummaryAgentDefaults(_ defaultsValue: SummaryAgentDefaults) {
        let defaults = UserDefaults.standard
        let language = AgentLanguageOption.normalizeCode(defaultsValue.targetLanguage)
        defaults.set(language, forKey: "Agent.Summary.DefaultTargetLanguage")
        defaults.set(defaultsValue.detailLevel.rawValue, forKey: "Agent.Summary.DefaultDetailLevel")
        setOptionalDefaultsValue(defaultsValue.primaryModelId, forKey: "Agent.Summary.PrimaryModelId", defaults: defaults)
        setOptionalDefaultsValue(defaultsValue.fallbackModelId, forKey: "Agent.Summary.FallbackModelId", defaults: defaults)
        finalizeAgentDefaultsSave(notificationName: .summaryAgentDefaultsDidChange)
    }

    // MARK: - Translation agent defaults

    func loadTranslationAgentDefaults() -> TranslationAgentDefaults {
        let defaults = UserDefaults.standard
        let language = AgentLanguageOption.normalizeCode(
            defaults.string(forKey: TranslationSettingsKey.targetLanguage) ?? AgentLanguageOption.english.code
        )
        let primaryModelId = (defaults.object(forKey: TranslationSettingsKey.primaryModelId) as? NSNumber)?.int64Value
        let fallbackModelId = (defaults.object(forKey: TranslationSettingsKey.fallbackModelId) as? NSNumber)?.int64Value
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

        return TranslationAgentDefaults(
            targetLanguage: language,
            primaryModelId: primaryModelId,
            fallbackModelId: fallbackModelId,
            promptStrategy: promptStrategy,
            concurrencyDegree: concurrencyDegree
        )
    }

    func saveTranslationAgentDefaults(_ defaultsValue: TranslationAgentDefaults) {
        let defaults = UserDefaults.standard
        let language = AgentLanguageOption.normalizeCode(defaultsValue.targetLanguage)
        defaults.set(language, forKey: TranslationSettingsKey.targetLanguage)
        setOptionalDefaultsValue(defaultsValue.primaryModelId, forKey: TranslationSettingsKey.primaryModelId, defaults: defaults)
        setOptionalDefaultsValue(defaultsValue.fallbackModelId, forKey: TranslationSettingsKey.fallbackModelId, defaults: defaults)
        defaults.set(defaultsValue.promptStrategy.rawValue, forKey: TranslationSettingsKey.promptStrategy)
        defaults.set(
            clampTranslationConcurrencyDegree(defaultsValue.concurrencyDegree),
            forKey: TranslationSettingsKey.concurrencyDegree
        )
        finalizeAgentDefaultsSave(notificationName: .translationAgentDefaultsDidChange)
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

    func loadTaggingAgentDefaults() -> TaggingAgentDefaults {
        let defaults = UserDefaults.standard
        let primaryModelId = (defaults.object(forKey: "Agent.Tagging.PrimaryModelId") as? NSNumber)?.int64Value
        let fallbackModelId = (defaults.object(forKey: "Agent.Tagging.FallbackModelId") as? NSNumber)?.int64Value
        return TaggingAgentDefaults(
            primaryModelId: primaryModelId,
            fallbackModelId: fallbackModelId
        )
    }

    func saveTaggingAgentDefaults(_ defaultsValue: TaggingAgentDefaults) {
        let defaults = UserDefaults.standard
        setOptionalDefaultsValue(defaultsValue.primaryModelId, forKey: "Agent.Tagging.PrimaryModelId", defaults: defaults)
        setOptionalDefaultsValue(defaultsValue.fallbackModelId, forKey: "Agent.Tagging.FallbackModelId", defaults: defaults)
        finalizeAgentDefaultsSave(notificationName: .taggingAgentDefaultsDidChange)
    }

}
