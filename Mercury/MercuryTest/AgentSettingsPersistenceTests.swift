import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Agent Settings Persistence")
struct AgentSettingsPersistenceTests {
    @Test("Refreshing configuration ensures fixed agent profiles exist")
    @MainActor
    func refreshConfigurationEnsuresFixedAgentProfilesExist() async throws {
        try await withPreparedAgentSettingsHarness { harness, _ in
            let appModel = harness.appModel
            _ = try await appModel.refreshAgentConfigurationSnapshot()

            let profiles = try await appModel.database.read { db in
                try AgentProfile.fetchAll(db)
            }

            #expect(profiles.count == AgentType.allCases.count)
            #expect(Set(profiles.map(\.agentType)) == Set(AgentType.allCases))
        }
    }

    @Test("Legacy defaults bootstrap fills translation route when database route is empty")
    @MainActor
    func legacyDefaultsBootstrapFillsTranslationRouteWhenDatabaseRouteIsEmpty() async throws {
        try await withPreparedAgentSettingsHarness { harness, defaults in
            let appModel = harness.appModel
            let modelIDs = try await seedAgentRouteModels(using: appModel, namePrefix: "Bootstrap Translation")

            defaults.set(modelIDs.primary, forKey: TranslationSettingsKey.primaryModelId)
            defaults.set(modelIDs.fallback, forKey: TranslationSettingsKey.fallbackModelId)

            let defaultsValue = try await appModel.loadTranslationAgentDefaults()
            let profile = try await loadAgentProfile(agentType: .translation, using: appModel)

            #expect(defaultsValue.primaryModelId == modelIDs.primary)
            #expect(defaultsValue.fallbackModelId == modelIDs.fallback)
            #expect(profile.primaryModelProfileId == modelIDs.primary)
            #expect(profile.fallbackModelProfileId == modelIDs.fallback)
        }
    }

    @Test("Existing database route ignores legacy translation defaults")
    @MainActor
    func existingDatabaseRouteIgnoresLegacyTranslationDefaults() async throws {
        try await withPreparedAgentSettingsHarness { harness, defaults in
            let appModel = harness.appModel
            let savedRoute = try await seedAgentRouteModels(using: appModel, namePrefix: "Saved Translation")
            let legacyRoute = try await seedAgentRouteModels(using: appModel, namePrefix: "Legacy Translation")

            try await appModel.saveTranslationAgentDefaults(
                TranslationAgentDefaults(
                    targetLanguage: "en",
                    primaryModelId: savedRoute.primary,
                    fallbackModelId: savedRoute.fallback,
                    promptStrategy: .standard,
                    concurrencyDegree: TranslationSettingsKey.defaultConcurrencyDegree
                )
            )

            defaults.set(legacyRoute.primary, forKey: TranslationSettingsKey.primaryModelId)
            defaults.set(legacyRoute.fallback, forKey: TranslationSettingsKey.fallbackModelId)

            let defaultsValue = try await appModel.loadTranslationAgentDefaults()
            let profile = try await loadAgentProfile(agentType: .translation, using: appModel)

            #expect(defaultsValue.primaryModelId == savedRoute.primary)
            #expect(defaultsValue.fallbackModelId == savedRoute.fallback)
            #expect(profile.primaryModelProfileId == savedRoute.primary)
            #expect(profile.fallbackModelProfileId == savedRoute.fallback)
        }
    }
}

@MainActor
private func withPreparedAgentSettingsHarness<Result>(
    _ body: @MainActor (AppModelTestHarness, UserDefaults) async throws -> Result
) async throws -> Result {
    let defaultsSuite = TestUserDefaultsSuite(prefix: "AgentSettingsPersistenceTests")
    defer { defaultsSuite.cleanup() }

    let harness = try AppModelTestHarness.inMemory(
        credentialStore: AgentSettingsTestCredentialStore(),
        agentSettingsDefaults: defaultsSuite.defaults
    )
    do {
        let result = try await body(harness, defaultsSuite.defaults)
        try await harness.shutdown()
        return result
    } catch {
        try? await harness.shutdown()
        throw error
    }
}

@MainActor
private func seedAgentRouteModels(
    using appModel: AppModel,
    namePrefix: String
) async throws -> (primary: Int64, fallback: Int64) {
    let provider = try await appModel.saveAgentProviderProfile(
        id: nil,
        name: "\(namePrefix) Provider",
        baseURL: "http://localhost:5810/v1",
        apiKey: "local",
        testModel: "qwen3",
        isEnabled: true
    )
    let providerId = try #require(provider.id)

    let primaryModel = try await appModel.saveAgentModelProfile(
        id: nil,
        providerProfileId: providerId,
        name: "\(namePrefix) Primary",
        modelName: "qwen3",
        isStreaming: true,
        temperature: nil,
        topP: nil,
        maxTokens: nil
    )
    let fallbackModel = try await appModel.saveAgentModelProfile(
        id: nil,
        providerProfileId: providerId,
        name: "\(namePrefix) Fallback",
        modelName: "qwen3-thinking",
        isStreaming: true,
        temperature: nil,
        topP: nil,
        maxTokens: nil
    )

    return (
        primary: try #require(primaryModel.id),
        fallback: try #require(fallbackModel.id)
    )
}

@MainActor
private func loadAgentProfile(agentType: AgentType, using appModel: AppModel) async throws -> AgentProfile {
    try await appModel.database.read { db in
        let profile = try AgentProfile
            .filter(Column("agentType") == agentType.rawValue)
            .fetchOne(db)
        return try #require(profile)
    }
}

private final class AgentSettingsTestCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func save(secret: String, for ref: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[ref] = secret
    }

    func readSecret(for ref: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let secret = storage[ref] else {
            throw CredentialStoreError.itemNotFound
        }
        return secret
    }

    func deleteSecret(for ref: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: ref)
    }
}
