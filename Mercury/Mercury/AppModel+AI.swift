//
//  AppModel+AI.swift
//  Mercury
//
//  Created by GitHub Copilot on 2026/2/18.
//

import Foundation
import GRDB

extension Notification.Name {
    static let openDebugIssuesRequested = Notification.Name("Mercury.OpenDebugIssuesRequested")
    static let summaryAgentDefaultsDidChange = Notification.Name("Mercury.SummaryAgentDefaultsDidChange")
}

struct SummaryAgentDefaults: Sendable {
    var targetLanguage: String
    var detailLevel: AISummaryDetailLevel
    var primaryModelId: Int64?
    var fallbackModelId: Int64?
}

enum AISettingsError: LocalizedError {
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
    func loadSummaryAgentDefaults() -> SummaryAgentDefaults {
        let defaults = UserDefaults.standard
        let language = SummaryLanguageOption.normalizeCode(
            defaults.string(forKey: "AI.Summary.DefaultTargetLanguage") ?? SummaryLanguageOption.english.code
        )
        let detailRaw = defaults.string(forKey: "AI.Summary.DefaultDetailLevel") ?? AISummaryDetailLevel.medium.rawValue
        let detail = AISummaryDetailLevel(rawValue: detailRaw) ?? .medium
        let primaryModelId = (defaults.object(forKey: "AI.Summary.PrimaryModelId") as? NSNumber)?.int64Value
        let fallbackModelId = (defaults.object(forKey: "AI.Summary.FallbackModelId") as? NSNumber)?.int64Value

        return SummaryAgentDefaults(
            targetLanguage: language,
            detailLevel: detail,
            primaryModelId: primaryModelId,
            fallbackModelId: fallbackModelId
        )
    }

    func saveSummaryAgentDefaults(_ defaultsValue: SummaryAgentDefaults) {
        let defaults = UserDefaults.standard
        let language = SummaryLanguageOption.normalizeCode(defaultsValue.targetLanguage)
        defaults.set(language, forKey: "AI.Summary.DefaultTargetLanguage")
        defaults.set(defaultsValue.detailLevel.rawValue, forKey: "AI.Summary.DefaultDetailLevel")

        if let primaryModelId = defaultsValue.primaryModelId {
            defaults.set(primaryModelId, forKey: "AI.Summary.PrimaryModelId")
        } else {
            defaults.removeObject(forKey: "AI.Summary.PrimaryModelId")
        }

        if let fallbackModelId = defaultsValue.fallbackModelId {
            defaults.set(fallbackModelId, forKey: "AI.Summary.FallbackModelId")
        } else {
            defaults.removeObject(forKey: "AI.Summary.FallbackModelId")
        }

        NotificationCenter.default.post(name: .summaryAgentDefaultsDidChange, object: nil)
    }

    func normalizeAIBaseURL(_ baseURL: String) throws -> String {
        try aiProviderValidationUseCase.normalizedBaseURL(baseURL)
    }

    func validateAIModelName(_ model: String) throws -> String {
        try aiProviderValidationUseCase.validateModelName(model)
    }

    func testAIProviderConnection(
        baseURL: String,
        apiKey: String,
        model: String,
        isStreaming: Bool = false,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        timeoutSeconds: TimeInterval = 120,
        systemMessage: String = "You are a concise assistant.",
        userMessage: String = "Reply with exactly: ok"
    ) async throws -> AIProviderConnectionTestResult {
        do {
            return try await aiProviderValidationUseCase.testConnection(
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
            reportAIFailureDebugIssue(
                source: "settings-smoke-test",
                baseURL: baseURL,
                model: model,
                error: error
            )
            throw error
        }
    }

    func testAIProviderConnection(
        baseURL: String,
        apiKeyRef: String,
        model: String,
        isStreaming: Bool = false,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        timeoutSeconds: TimeInterval = 120,
        systemMessage: String = "You are a concise assistant.",
        userMessage: String = "Reply with exactly: ok"
    ) async throws -> AIProviderConnectionTestResult {
        do {
            return try await aiProviderValidationUseCase.testConnectionWithStoredCredential(
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
            reportAIFailureDebugIssue(
                source: "settings-smoke-test",
                baseURL: baseURL,
                model: model,
                error: error
            )
            throw error
        }
    }

    func loadAIProviderProfiles() async throws -> [AIProviderProfile] {
        try await database.read { db in
            try AIProviderProfile.fetchAll(db)
        }
    }

    func saveAIProviderProfile(
        id: Int64?,
        name: String,
        baseURL: String,
        apiKey: String?,
        testModel: String,
        isEnabled: Bool
    ) async throws -> AIProviderProfile {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.isEmpty == false else {
            throw AISettingsError.providerNameRequired
        }
        let normalizedBaseURL = try normalizeAIBaseURL(baseURL)
        let normalizedTestModel = try validateAIModelName(testModel)
        let now = Date()

        return try await database.write { [self] db in
            let providerCount = try AIProviderProfile.fetchCount(db)
            let existing: AIProviderProfile?
            if let id {
                existing = try AIProviderProfile.filter(Column("id") == id).fetchOne(db)
            } else {
                existing = nil
            }

            let shouldBeDefault = existing?.isDefault ?? (providerCount == 0)

            var profile = existing ?? AIProviderProfile(
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
                throw AISettingsError.providerAPIKeyMissing
            }

            try profile.save(db)
            return profile
        }
    }

    func setDefaultAIProviderProfile(id: Int64) async throws {
        try await database.write { db in
            guard var selected = try AIProviderProfile.filter(Column("id") == id).fetchOne(db) else {
                throw AISettingsError.providerNotFound
            }
            guard selected.isDefault == false else {
                return
            }

            _ = try AIProviderProfile
                .filter(Column("id") != id)
                .updateAll(db, Column("isDefault").set(to: false))

            selected.isDefault = true
            selected.updatedAt = Date()
            try selected.save(db)
        }
    }

    func hasStoredAIProviderAPIKey(ref: String) -> Bool {
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

    func deleteAIProviderProfile(id: Int64) async throws {
        try await database.write { [self] db in
            guard let profile = try AIProviderProfile.filter(Column("id") == id).fetchOne(db) else {
                return
            }

            if profile.isDefault {
                throw AISettingsError.cannotDeleteDefaultProvider
            }

            guard let fallbackProviderId = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM ai_provider_profile WHERE isDefault = 1 AND id <> ? ORDER BY updatedAt DESC LIMIT 1",
                arguments: [id]
            ) else {
                throw AISettingsError.noDefaultProviderAvailable
            }

            _ = try AIModelProfile
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
    }

    func loadAIModelProfiles() async throws -> [AIModelProfile] {
        try await database.read { db in
            try AIModelProfile
                .order(Column("isDefault").desc)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    func saveAIModelProfile(
        id: Int64?,
        providerProfileId: Int64,
        name: String,
        modelName: String,
        isStreaming: Bool,
        temperature: Double?,
        topP: Double?,
        maxTokens: Int?
    ) async throws -> AIModelProfile {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.isEmpty == false else {
            throw AISettingsError.modelProfileNameRequired
        }

        let validatedModelName = try validateAIModelName(modelName)
        let now = Date()

        return try await database.write { db in
            let modelCount = try AIModelProfile.fetchCount(db)
            let existing: AIModelProfile?
            if let id {
                existing = try AIModelProfile.filter(Column("id") == id).fetchOne(db)
            } else {
                existing = nil
            }

            let shouldBeDefault = existing?.isDefault ?? (modelCount == 0)

            var profile = existing ?? AIModelProfile(
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
    }

    func setDefaultAIModelProfile(id: Int64) async throws {
        try await database.write { db in
            guard var selected = try AIModelProfile.filter(Column("id") == id).fetchOne(db) else {
                throw AISettingsError.modelNotFound
            }
            guard selected.isDefault == false else {
                return
            }

            _ = try AIModelProfile
                .filter(Column("id") != id)
                .updateAll(db, Column("isDefault").set(to: false))

            selected.isDefault = true
            selected.updatedAt = Date()
            try selected.save(db)
        }
    }

    func deleteAIModelProfile(id: Int64) async throws {
        try await database.write { db in
            guard let profile = try AIModelProfile.filter(Column("id") == id).fetchOne(db) else {
                return
            }
            if profile.isDefault {
                throw AISettingsError.cannotDeleteDefaultModel
            }
            _ = try profile.delete(db)
        }
    }

    func testAIModelProfile(
        modelProfileId: Int64,
        systemMessage: String,
        userMessage: String,
        timeoutSeconds: TimeInterval = 120
    ) async throws -> AIProviderConnectionTestResult {
        let pair = try await database.read { db in
            guard let model = try AIModelProfile.filter(Column("id") == modelProfileId).fetchOne(db) else {
                throw AISettingsError.modelNotFound
            }
            guard let provider = try AIProviderProfile.filter(Column("id") == model.providerProfileId).fetchOne(db) else {
                throw AISettingsError.providerNotFound
            }
            return (provider, model)
        }

        return try await testAIProviderConnection(
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
        return "ai-provider-\(slug)-\(short)"
    }

    private func reportAIFailureDebugIssue(
        source: String,
        baseURL: String,
        model: String,
        error: Error
    ) {
        reportDebugIssue(
            title: "AI Provider Test Failed",
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
