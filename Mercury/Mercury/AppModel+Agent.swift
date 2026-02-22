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
    static let translationAgentDefaultsDidChange = Notification.Name("Mercury.TranslationAgentDefaultsDidChange")
}

struct SummaryAgentDefaults: Sendable {
    var targetLanguage: String
    var detailLevel: SummaryDetailLevel
    var primaryModelId: Int64?
    var fallbackModelId: Int64?
}

struct TranslationAgentDefaults: Sendable {
    var targetLanguage: String
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

        NotificationCenter.default.post(name: .summaryAgentDefaultsDidChange, object: nil)
        Task { await refreshAgentAvailability() }
    }

    func loadTranslationAgentDefaults() -> TranslationAgentDefaults {
        let defaults = UserDefaults.standard
        let language = AgentLanguageOption.normalizeCode(
            defaults.string(forKey: "Agent.Translation.DefaultTargetLanguage") ?? AgentLanguageOption.english.code
        )
        let primaryModelId = (defaults.object(forKey: "Agent.Translation.PrimaryModelId") as? NSNumber)?.int64Value
        let fallbackModelId = (defaults.object(forKey: "Agent.Translation.FallbackModelId") as? NSNumber)?.int64Value

        return TranslationAgentDefaults(
            targetLanguage: language,
            primaryModelId: primaryModelId,
            fallbackModelId: fallbackModelId
        )
    }

    func saveTranslationAgentDefaults(_ defaultsValue: TranslationAgentDefaults) {
        let defaults = UserDefaults.standard
        let rawLanguage = defaultsValue.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawLanguage.isEmpty == false {
            let language = AgentLanguageOption.normalizeCode(rawLanguage)
            defaults.set(language, forKey: "Agent.Translation.DefaultTargetLanguage")
        }

        if let primaryModelId = defaultsValue.primaryModelId {
            defaults.set(primaryModelId, forKey: "Agent.Translation.PrimaryModelId")
        } else {
            defaults.removeObject(forKey: "Agent.Translation.PrimaryModelId")
        }

        if let fallbackModelId = defaultsValue.fallbackModelId {
            defaults.set(fallbackModelId, forKey: "Agent.Translation.FallbackModelId")
        } else {
            defaults.removeObject(forKey: "Agent.Translation.FallbackModelId")
        }

        NotificationCenter.default.post(name: .translationAgentDefaultsDidChange, object: nil)
        Task { await refreshAgentAvailability() }
    }

    func normalizeAgentBaseURL(_ baseURL: String) throws -> String {
        try agentProviderValidationUseCase.normalizedBaseURL(baseURL)
    }

    func validateAgentModelName(_ model: String) throws -> String {
        try agentProviderValidationUseCase.validateModelName(model)
    }

    func testAgentProviderConnection(
        baseURL: String,
        apiKey: String,
        model: String,
        isStreaming: Bool = false,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        timeoutSeconds: TimeInterval = 120,
        systemMessage: String = "You are a concise agent.",
        userMessage: String = "Reply with exactly: ok"
    ) async throws -> AgentProviderConnectionTestResult {
        do {
            return try await agentProviderValidationUseCase.testConnection(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                isStreaming: isStreaming,
                temperature: temperature,
                topP: topP,
                maxTokens: maxTokens,
                timeoutSeconds: timeoutSeconds,
                systemMessage: systemMessage,
                userMessage: userMessage
            )
        } catch {
            reportAgentFailureDebugIssue(
                source: "settings-smoke-test",
                baseURL: baseURL,
                model: model,
                error: error
            )
            throw error
        }
    }

    func testAgentProviderConnection(
        baseURL: String,
        apiKeyRef: String,
        model: String,
        isStreaming: Bool = false,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        timeoutSeconds: TimeInterval = 120,
        systemMessage: String = "You are a concise agent.",
        userMessage: String = "Reply with exactly: ok"
    ) async throws -> AgentProviderConnectionTestResult {
        do {
            return try await agentProviderValidationUseCase.testConnectionWithStoredCredential(
                baseURL: baseURL,
                apiKeyRef: apiKeyRef,
                model: model,
                isStreaming: isStreaming,
                temperature: temperature,
                topP: topP,
                maxTokens: maxTokens,
                timeoutSeconds: timeoutSeconds,
                systemMessage: systemMessage,
                userMessage: userMessage
            )
        } catch {
            reportAgentFailureDebugIssue(
                source: "settings-smoke-test",
                baseURL: baseURL,
                model: model,
                error: error
            )
            throw error
        }
    }

    func loadAgentProviderProfiles() async throws -> [AgentProviderProfile] {
        try await database.read { db in
            try AgentProviderProfile.fetchAll(db)
        }
    }

    func saveAgentProviderProfile(
        id: Int64?,
        name: String,
        baseURL: String,
        apiKey: String?,
        testModel: String,
        isEnabled: Bool
    ) async throws -> AgentProviderProfile {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.isEmpty == false else {
            throw AgentSettingsError.providerNameRequired
        }
        let normalizedBaseURL = try normalizeAgentBaseURL(baseURL)
        let normalizedTestModel = try validateAgentModelName(testModel)
        let now = Date()

        let savedProfile = try await database.write { [self] db in
            let providerCount = try AgentProviderProfile.fetchCount(db)
            let existing: AgentProviderProfile?
            if let id {
                existing = try AgentProviderProfile.filter(Column("id") == id).fetchOne(db)
            } else {
                existing = nil
            }

            let shouldBeDefault = existing?.isDefault ?? (providerCount == 0)

            var profile = existing ?? AgentProviderProfile(
                id: nil,
                name: normalizedName,
                baseURL: normalizedBaseURL,
                apiKeyRef: "",
                testModel: normalizedTestModel,
                isDefault: shouldBeDefault,
                isEnabled: isEnabled,
                createdAt: now,
                updatedAt: now
            )

            profile.name = normalizedName
            profile.baseURL = normalizedBaseURL
            profile.testModel = normalizedTestModel
            profile.isDefault = shouldBeDefault
            profile.isEnabled = isEnabled
            profile.updatedAt = now

            let trimmedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmedAPIKey, trimmedAPIKey.isEmpty == false {
                let ref = profile.apiKeyRef.isEmpty ? self.makeProviderAPIKeyRef(name: normalizedName) : profile.apiKeyRef
                try self.credentialStore.save(secret: trimmedAPIKey, for: ref)
                profile.apiKeyRef = ref
            }

            if profile.apiKeyRef.isEmpty {
                throw AgentSettingsError.providerAPIKeyMissing
            }

            try profile.save(db)
            return profile
        }
        await refreshAgentAvailability()
        return savedProfile
    }

    func setDefaultAgentProviderProfile(id: Int64) async throws {
        try await database.write { db in
            guard var selected = try AgentProviderProfile.filter(Column("id") == id).fetchOne(db) else {
                throw AgentSettingsError.providerNotFound
            }
            guard selected.isDefault == false else {
                return
            }

            _ = try AgentProviderProfile
                .filter(Column("id") != id)
                .updateAll(db, Column("isDefault").set(to: false))

            selected.isDefault = true
            selected.updatedAt = Date()
            try selected.save(db)
        }
    }

    func hasStoredAgentProviderAPIKey(ref: String) -> Bool {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return false
        }
        do {
            _ = try credentialStore.readSecret(for: trimmed)
            return true
        } catch {
            return false
        }
    }

    func deleteAgentProviderProfile(id: Int64) async throws {
        try await database.write { [self] db in
            guard let profile = try AgentProviderProfile.filter(Column("id") == id).fetchOne(db) else {
                return
            }

            if profile.isDefault {
                throw AgentSettingsError.cannotDeleteDefaultProvider
            }

            guard let fallbackProviderId = try Int64.fetchOne(
                db,
                AgentProviderProfile
                    .select(Column("id"))
                    .filter(Column("isDefault") == true)
                    .filter(Column("id") != id)
                    .order(Column("updatedAt").desc)
                    .limit(1)
            ) else {
                throw AgentSettingsError.noDefaultProviderAvailable
            }

            _ = try AgentModelProfile
                .filter(Column("providerProfileId") == id)
                .updateAll(
                    db,
                    Column("providerProfileId").set(to: fallbackProviderId),
                    Column("updatedAt").set(to: Date())
                )

            if profile.apiKeyRef.isEmpty == false {
                try? self.credentialStore.deleteSecret(for: profile.apiKeyRef)
            }
            _ = try profile.delete(db)
        }
        await refreshAgentAvailability()
    }

    func loadAgentModelProfiles() async throws -> [AgentModelProfile] {
        try await database.read { db in
            try AgentModelProfile
                .order(Column("isDefault").desc)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    func saveAgentModelProfile(
        id: Int64?,
        providerProfileId: Int64,
        name: String,
        modelName: String,
        isStreaming: Bool,
        temperature: Double?,
        topP: Double?,
        maxTokens: Int?
    ) async throws -> AgentModelProfile {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.isEmpty == false else {
            throw AgentSettingsError.modelProfileNameRequired
        }

        let validatedModelName = try validateAgentModelName(modelName)
        let now = Date()

        let savedProfile = try await database.write { db in
            let modelCount = try AgentModelProfile.fetchCount(db)
            let existing: AgentModelProfile?
            if let id {
                existing = try AgentModelProfile.filter(Column("id") == id).fetchOne(db)
            } else {
                existing = nil
            }

            let shouldBeDefault = existing?.isDefault ?? (modelCount == 0)

            var profile = existing ?? AgentModelProfile(
                id: nil,
                providerProfileId: providerProfileId,
                name: normalizedName,
                modelName: validatedModelName,
                temperature: nil,
                topP: nil,
                maxTokens: nil,
                isStreaming: isStreaming,
                supportsTagging: true,
                supportsSummary: true,
                supportsTranslation: true,
                isDefault: shouldBeDefault,
                isEnabled: true,
                lastTestedAt: nil,
                createdAt: now,
                updatedAt: now
            )

            profile.providerProfileId = providerProfileId
            profile.name = normalizedName
            profile.modelName = validatedModelName
            profile.isDefault = shouldBeDefault
            profile.isStreaming = isStreaming
            profile.temperature = temperature
            profile.topP = topP
            profile.maxTokens = maxTokens
            profile.updatedAt = now

            try profile.save(db)
            return profile
        }
        await refreshAgentAvailability()
        return savedProfile
    }

    func setDefaultAgentModelProfile(id: Int64) async throws {
        try await database.write { db in
            guard var selected = try AgentModelProfile.filter(Column("id") == id).fetchOne(db) else {
                throw AgentSettingsError.modelNotFound
            }
            guard selected.isDefault == false else {
                return
            }

            _ = try AgentModelProfile
                .filter(Column("id") != id)
                .updateAll(db, Column("isDefault").set(to: false))

            selected.isDefault = true
            selected.updatedAt = Date()
            try selected.save(db)
        }
    }

    func deleteAgentModelProfile(id: Int64) async throws {
        try await database.write { db in
            guard let profile = try AgentModelProfile.filter(Column("id") == id).fetchOne(db) else {
                return
            }
            if profile.isDefault {
                throw AgentSettingsError.cannotDeleteDefaultModel
            }
            _ = try profile.delete(db)
        }
        await refreshAgentAvailability()
    }

    func testAgentModelProfile(
        modelProfileId: Int64,
        systemMessage: String,
        userMessage: String,
        timeoutSeconds: TimeInterval = 120
    ) async throws -> AgentProviderConnectionTestResult {
        let pair = try await database.read { db in
            guard let model = try AgentModelProfile.filter(Column("id") == modelProfileId).fetchOne(db) else {
                throw AgentSettingsError.modelNotFound
            }
            guard let provider = try AgentProviderProfile.filter(Column("id") == model.providerProfileId).fetchOne(db) else {
                throw AgentSettingsError.providerNotFound
            }
            return (provider, model)
        }

        return try await testAgentProviderConnection(
            baseURL: pair.0.baseURL,
            apiKeyRef: pair.0.apiKeyRef,
            model: pair.1.modelName,
            isStreaming: pair.1.isStreaming,
            temperature: pair.1.temperature,
            topP: pair.1.topP,
            maxTokens: pair.1.maxTokens,
            timeoutSeconds: timeoutSeconds,
            systemMessage: systemMessage,
            userMessage: userMessage
        )
    }

    func requestOpenDebugIssues() {
        NotificationCenter.default.post(name: .openDebugIssuesRequested, object: nil)
    }

    private func makeProviderAPIKeyRef(name: String) -> String {
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let short = UUID().uuidString.prefix(8)
        return "agent-provider-\(slug)-\(short)"
    }

    private func reportAgentFailureDebugIssue(
        source: String,
        baseURL: String,
        model: String,
        error: Error
    ) {
        reportDebugIssue(
            title: "Agent Provider Test Failed",
            detail: [
                "source=\(source)",
                "baseURL=\(baseURL)",
                "model=\(model)",
                "error=\(error.localizedDescription)"
            ].joined(separator: "\n"),
            category: .task
        )
    }
}
