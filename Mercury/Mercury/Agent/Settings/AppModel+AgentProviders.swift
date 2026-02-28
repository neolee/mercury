import Foundation
import GRDB

extension AppModel {
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
        timeoutSeconds: TimeInterval = TaskTimeoutPolicy.providerValidationTimeoutSeconds,
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
        timeoutSeconds: TimeInterval = TaskTimeoutPolicy.providerValidationTimeoutSeconds,
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
            try AgentProviderProfile
                .filter(Column("isArchived") == false)
                .fetchAll(db)
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
            let activeProviderCount = try AgentProviderProfile
                .filter(Column("isArchived") == false)
                .fetchCount(db)
            let existing: AgentProviderProfile?
            if let id {
                existing = try AgentProviderProfile.filter(Column("id") == id).fetchOne(db)
            } else {
                existing = try AgentProviderProfile
                    .filter(Column("baseURL") == normalizedBaseURL)
                    .filter(Column("isArchived") == true)
                    .order(Column("updatedAt").desc)
                    .fetchOne(db)
            }

            let shouldBeDefault = existing?.isDefault ?? (activeProviderCount == 0)

            var profile = existing ?? AgentProviderProfile(
                id: nil,
                name: normalizedName,
                baseURL: normalizedBaseURL,
                apiKeyRef: "",
                testModel: normalizedTestModel,
                isDefault: shouldBeDefault,
                isEnabled: isEnabled,
                isArchived: false,
                archivedAt: nil,
                createdAt: now,
                updatedAt: now
            )

            profile.name = normalizedName
            profile.baseURL = normalizedBaseURL
            profile.testModel = normalizedTestModel
            profile.isDefault = shouldBeDefault
            profile.isEnabled = isEnabled
            profile.isArchived = false
            profile.archivedAt = nil
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
            guard var selected = try AgentProviderProfile
                .filter(Column("id") == id)
                .filter(Column("isArchived") == false)
                .fetchOne(db) else {
                throw AgentSettingsError.providerNotFound
            }
            guard selected.isDefault == false else {
                return
            }

            _ = try AgentProviderProfile
                .filter(Column("id") != id)
                .filter(Column("isArchived") == false)
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
        try await database.write { db in
            guard let profile = try AgentProviderProfile.filter(Column("id") == id).fetchOne(db) else {
                return
            }

            if profile.isDefault {
                throw AgentSettingsError.cannotDeleteDefaultProvider
            }

            let now = Date()

            _ = try AgentModelProfile
                .filter(Column("providerProfileId") == id)
                .filter(Column("isArchived") == false)
                .updateAll(
                    db,
                    Column("isArchived").set(to: true),
                    Column("archivedAt").set(to: now),
                    Column("isDefault").set(to: false),
                    Column("updatedAt").set(to: now)
                )

            var archived = profile
            archived.isArchived = true
            archived.archivedAt = now
            archived.isDefault = false
            archived.updatedAt = now
            try archived.save(db)
        }
        await refreshAgentAvailability()
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
