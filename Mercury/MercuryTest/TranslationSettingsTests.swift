import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Translation Settings")
struct TranslationSettingsTests {
    @Test("Translation defaults persist and reload")
    @MainActor
    func translationDefaultsPersistAndReload() async throws {
        let defaultsSuite = TestUserDefaultsSuite(prefix: "TranslationSettingsTests")
        defer { defaultsSuite.cleanup() }

        try await AppModelTestHarness.withInMemory(
            credentialStore: TranslationTestCredentialStore(),
            agentSettingsDefaults: defaultsSuite.defaults
        ) { harness in
            let appModel = harness.appModel

            #expect(
                (try await appModel.loadTranslationAgentDefaults()).concurrencyDegree
                    == TranslationSettingsKey.defaultConcurrencyDegree
            )

            let modelIDs = try await seedTranslationModelIDs(using: appModel)

            try await appModel.saveTranslationAgentDefaults(
                TranslationAgentDefaults(
                    targetLanguage: "zh-cn",
                    primaryModelId: modelIDs.primary,
                    fallbackModelId: modelIDs.fallback,
                    promptStrategy: .hyMTOptimized,
                    concurrencyDegree: 5
                )
            )

            let loaded = try await appModel.loadTranslationAgentDefaults()
            #expect(loaded.targetLanguage == "zh-Hans")
            #expect(loaded.primaryModelId == modelIDs.primary)
            #expect(loaded.fallbackModelId == modelIDs.fallback)
            #expect(loaded.promptStrategy == .hyMTOptimized)
            #expect(loaded.concurrencyDegree == 5)
            let persistedProfile = try await loadAgentProfile(agentType: .translation, using: appModel)
            #expect(persistedProfile.primaryModelProfileId == modelIDs.primary)
            #expect(persistedProfile.fallbackModelProfileId == modelIDs.fallback)

            try await appModel.saveTranslationAgentDefaults(
                TranslationAgentDefaults(
                    targetLanguage: "",
                    primaryModelId: nil,
                    fallbackModelId: nil,
                    promptStrategy: .standard,
                    concurrencyDegree: 999
                )
            )

            let reset = try await appModel.loadTranslationAgentDefaults()
            #expect(reset.targetLanguage == AgentLanguageOption.english.code)
            #expect(reset.primaryModelId == nil)
            #expect(reset.fallbackModelId == nil)
            #expect(reset.promptStrategy == .standard)
            #expect(reset.concurrencyDegree == TranslationSettingsKey.concurrencyRange.upperBound)
            let resetProfile = try await loadAgentProfile(agentType: .translation, using: appModel)
            #expect(resetProfile.primaryModelProfileId == nil)
            #expect(resetProfile.fallbackModelProfileId == nil)

            try await appModel.saveTranslationAgentDefaults(
                TranslationAgentDefaults(
                    targetLanguage: "en",
                    primaryModelId: nil,
                    fallbackModelId: nil,
                    promptStrategy: .standard,
                    concurrencyDegree: 0
                )
            )

            let clampedLow = try await appModel.loadTranslationAgentDefaults()
            #expect(clampedLow.concurrencyDegree == TranslationSettingsKey.concurrencyRange.lowerBound)
        }
    }

    @Test("Agent configuration snapshot normalizes archived translation route without rewriting persisted settings")
    @MainActor
    func agentConfigurationSnapshotNormalizesArchivedTranslationRouteWithoutRewritingPersistedSettings() async throws {
        let defaultsSuite = TestUserDefaultsSuite(prefix: "TranslationSettingsTests")
        defer { defaultsSuite.cleanup() }

        try await AppModelTestHarness.withInMemory(
            credentialStore: TranslationTestCredentialStore(),
            agentSettingsDefaults: defaultsSuite.defaults
        ) { harness in
            let appModel = harness.appModel

            let provider = try await appModel.saveAgentProviderProfile(
                id: nil,
                name: "Local Test Provider",
                baseURL: "http://localhost:5810/v1",
                apiKey: "local",
                testModel: "qwen3",
                isEnabled: true
            )
            let providerId = try #require(provider.id)

            let model = try await appModel.saveAgentModelProfile(
                id: nil,
                providerProfileId: providerId,
                name: "Translation Model",
                modelName: "qwen3",
                isStreaming: true,
                temperature: nil,
                topP: nil,
                maxTokens: nil
            )
            let modelId = try #require(model.id)

            let replacementModel = try await appModel.saveAgentModelProfile(
                id: nil,
                providerProfileId: providerId,
                name: "Replacement Translation Model",
                modelName: "qwen3-thinking",
                isStreaming: true,
                temperature: nil,
                topP: nil,
                maxTokens: nil
            )
            let replacementModelId = try #require(replacementModel.id)
            try await appModel.setDefaultAgentModelProfile(id: replacementModelId)

            try await appModel.saveTranslationAgentDefaults(
                TranslationAgentDefaults(
                    targetLanguage: "en",
                    primaryModelId: modelId,
                    fallbackModelId: modelId,
                    promptStrategy: .hyMTOptimized,
                    concurrencyDegree: 3
                )
            )

            try await appModel.deleteAgentModelProfile(id: modelId)

            let snapshot = try await appModel.refreshAgentConfigurationSnapshot()
            #expect(snapshot.translationDefaults.primaryModelId == nil)
            #expect(snapshot.translationDefaults.fallbackModelId == nil)
            #expect(snapshot.availability.translation == false)
            #expect(snapshot.translationProfile.primaryModelProfileId == modelId)
            #expect(snapshot.translationProfile.fallbackModelProfileId == nil)

            let reloadedDefaults = try await appModel.loadTranslationAgentDefaults()
            #expect(reloadedDefaults.primaryModelId == modelId)
            #expect(reloadedDefaults.fallbackModelId == nil)
            #expect(reloadedDefaults.promptStrategy == .hyMTOptimized)
        }
    }
}

@MainActor
private func seedTranslationModelIDs(using appModel: AppModel) async throws -> (primary: Int64, fallback: Int64) {
    let provider = try await appModel.saveAgentProviderProfile(
        id: nil,
        name: "Settings Test Provider",
        baseURL: "http://localhost:5810/v1",
        apiKey: "local",
        testModel: "qwen3",
        isEnabled: true
    )
    let providerId = try #require(provider.id)

    let primaryModel = try await appModel.saveAgentModelProfile(
        id: nil,
        providerProfileId: providerId,
        name: "Settings Translation Primary",
        modelName: "qwen3",
        isStreaming: true,
        temperature: nil,
        topP: nil,
        maxTokens: nil
    )
    let fallbackModel = try await appModel.saveAgentModelProfile(
        id: nil,
        providerProfileId: providerId,
        name: "Settings Translation Fallback",
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

private final class TranslationTestCredentialStore: CredentialStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

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
