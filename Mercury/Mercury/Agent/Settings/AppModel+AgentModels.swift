import Foundation
import GRDB

extension AppModel {
    func loadActiveModelNames(forProviderId providerId: Int64) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(
                db,
                AgentModelProfile
                    .select(Column("name"))
                    .filter(Column("providerProfileId") == providerId)
                    .filter(Column("isArchived") == false)
                    .order(Column("updatedAt").desc)
            )
        }
    }

    func loadAgentModelProfiles() async throws -> [AgentModelProfile] {
        try await database.read { db in
            try AgentModelProfile
                .filter(Column("isArchived") == false)
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
            let activeModelCount = try AgentModelProfile
                .filter(Column("isArchived") == false)
                .fetchCount(db)
            let existing: AgentModelProfile?
            if let id {
                existing = try AgentModelProfile.filter(Column("id") == id).fetchOne(db)
            } else {
                existing = try AgentModelProfile
                    .filter(Column("providerProfileId") == providerProfileId)
                    .filter(Column("modelName") == validatedModelName)
                    .filter(Column("isArchived") == true)
                    .order(Column("updatedAt").desc)
                    .fetchOne(db)
            }

            let shouldBeDefault = existing?.isDefault ?? (activeModelCount == 0)

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
                isArchived: false,
                archivedAt: nil,
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
            profile.isArchived = false
            profile.archivedAt = nil
            profile.updatedAt = now

            try profile.save(db)
            return profile
        }
        await refreshAgentAvailability()
        return savedProfile
    }

    func setDefaultAgentModelProfile(id: Int64) async throws {
        try await database.write { db in
            guard var selected = try AgentModelProfile
                .filter(Column("id") == id)
                .filter(Column("isArchived") == false)
                .fetchOne(db) else {
                throw AgentSettingsError.modelNotFound
            }
            guard selected.isDefault == false else {
                return
            }

            _ = try AgentModelProfile
                .filter(Column("id") != id)
                .filter(Column("isArchived") == false)
                .updateAll(db, Column("isDefault").set(to: false))

            selected.isDefault = true
            selected.updatedAt = Date()
            try selected.save(db)
        }
    }

    func deleteAgentModelProfile(id: Int64) async throws {
        try await database.write { db in
            guard var profile = try AgentModelProfile.filter(Column("id") == id).fetchOne(db) else {
                return
            }
            if profile.isDefault {
                throw AgentSettingsError.cannotDeleteDefaultModel
            }
            profile.isArchived = true
            profile.archivedAt = Date()
            profile.updatedAt = Date()
            try profile.save(db)
        }
        await refreshAgentAvailability()
    }

    func testAgentModelProfile(
        modelProfileId: Int64,
        systemMessage: String,
        userMessage: String,
        timeoutSeconds: TimeInterval = TaskTimeoutPolicy.providerValidationTimeoutSeconds
    ) async throws -> AgentProviderConnectionTestResult {
        let pair = try await database.read { db in
            guard let model = try AgentModelProfile
                .filter(Column("id") == modelProfileId)
                .filter(Column("isArchived") == false)
                .fetchOne(db) else {
                throw AgentSettingsError.modelNotFound
            }
            guard let provider = try AgentProviderProfile
                .filter(Column("id") == model.providerProfileId)
                .filter(Column("isArchived") == false)
                .fetchOne(db) else {
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
}
