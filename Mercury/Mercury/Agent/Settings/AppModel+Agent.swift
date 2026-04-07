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
        storeSummaryAgentDefaults(
            defaultsValue,
            postChangeNotification: true,
            scheduleConfigurationRefresh: true
        )
    }

    func storeSummaryAgentDefaults(
        _ defaultsValue: SummaryAgentDefaults,
        postChangeNotification: Bool,
        scheduleConfigurationRefresh: Bool
    ) {
        let defaults = UserDefaults.standard
        let language = AgentLanguageOption.normalizeCode(defaultsValue.targetLanguage)
        defaults.set(language, forKey: "Agent.Summary.DefaultTargetLanguage")
        defaults.set(defaultsValue.detailLevel.rawValue, forKey: "Agent.Summary.DefaultDetailLevel")

        if let primaryModelId = defaultsValue.primaryModelId {
            defaults.set(primaryModelId, forKey: "Agent.Summary.PrimaryModelId")
        } else {
            defaults.removeObject(forKey: "Agent.Summary.PrimaryModelId")
        }

        if let fallbackModelId = defaultsValue.fallbackModelId {
            defaults.set(fallbackModelId, forKey: "Agent.Summary.FallbackModelId")
        } else {
            defaults.removeObject(forKey: "Agent.Summary.FallbackModelId")
        }

        if postChangeNotification {
            NotificationCenter.default.post(name: .summaryAgentDefaultsDidChange, object: nil)
        }
        if scheduleConfigurationRefresh {
            Task { await refreshAgentConfigurationSnapshotSafely() }
        }
    }

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
        storeTranslationAgentDefaults(
            defaultsValue,
            postChangeNotification: true,
            scheduleConfigurationRefresh: true
        )
    }

    func storeTranslationAgentDefaults(
        _ defaultsValue: TranslationAgentDefaults,
        postChangeNotification: Bool,
        scheduleConfigurationRefresh: Bool
    ) {
        let defaults = UserDefaults.standard
        let rawLanguage = defaultsValue.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawLanguage.isEmpty == false {
            let language = AgentLanguageOption.normalizeCode(rawLanguage)
            defaults.set(language, forKey: TranslationSettingsKey.targetLanguage)
        }

        if let primaryModelId = defaultsValue.primaryModelId {
            defaults.set(primaryModelId, forKey: TranslationSettingsKey.primaryModelId)
        } else {
            defaults.removeObject(forKey: TranslationSettingsKey.primaryModelId)
        }

        if let fallbackModelId = defaultsValue.fallbackModelId {
            defaults.set(fallbackModelId, forKey: TranslationSettingsKey.fallbackModelId)
        } else {
            defaults.removeObject(forKey: TranslationSettingsKey.fallbackModelId)
        }
        defaults.set(defaultsValue.promptStrategy.rawValue, forKey: TranslationSettingsKey.promptStrategy)
        defaults.set(
            clampTranslationConcurrencyDegree(defaultsValue.concurrencyDegree),
            forKey: TranslationSettingsKey.concurrencyDegree
        )

        if postChangeNotification {
            NotificationCenter.default.post(name: .translationAgentDefaultsDidChange, object: nil)
        }
        if scheduleConfigurationRefresh {
            Task { await refreshAgentConfigurationSnapshotSafely() }
        }
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
        storeTaggingAgentDefaults(
            defaultsValue,
            postChangeNotification: true,
            scheduleConfigurationRefresh: true
        )
    }

    func storeTaggingAgentDefaults(
        _ defaultsValue: TaggingAgentDefaults,
        postChangeNotification: Bool,
        scheduleConfigurationRefresh: Bool
    ) {
        let defaults = UserDefaults.standard
        if let primaryModelId = defaultsValue.primaryModelId {
            defaults.set(primaryModelId, forKey: "Agent.Tagging.PrimaryModelId")
        } else {
            defaults.removeObject(forKey: "Agent.Tagging.PrimaryModelId")
        }
        if let fallbackModelId = defaultsValue.fallbackModelId {
            defaults.set(fallbackModelId, forKey: "Agent.Tagging.FallbackModelId")
        } else {
            defaults.removeObject(forKey: "Agent.Tagging.FallbackModelId")
        }
        if postChangeNotification {
            NotificationCenter.default.post(name: .taggingAgentDefaultsDidChange, object: nil)
        }
        if scheduleConfigurationRefresh {
            Task { await refreshAgentConfigurationSnapshotSafely() }
        }
    }

}
