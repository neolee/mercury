import Foundation
import Testing
@testable import Mercury

@Suite("Translation Settings")
struct TranslationSettingsTests {
    @Test("Translation defaults persist and reload")
    @MainActor
    func translationDefaultsPersistAndReload() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: TranslationTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel

            let keys = [
                "Agent.Translation.DefaultTargetLanguage",
                "Agent.Translation.PrimaryModelId",
                "Agent.Translation.FallbackModelId",
                TranslationSettingsKey.promptStrategy,
                TranslationSettingsKey.concurrencyDegree
            ]
            let savedValues = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
            defer {
                for (key, value) in savedValues {
                    if let value {
                        UserDefaults.standard.set(value, forKey: key)
                    } else {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                }
            }
            keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
            #expect(
                appModel.loadTranslationAgentDefaults().concurrencyDegree
                    == TranslationSettingsKey.defaultConcurrencyDegree
            )

            appModel.saveTranslationAgentDefaults(
                TranslationAgentDefaults(
                    targetLanguage: "zh-cn",
                    primaryModelId: 101,
                    fallbackModelId: 202,
                    promptStrategy: .hyMTOptimized,
                    concurrencyDegree: 5
                )
            )

            let loaded = appModel.loadTranslationAgentDefaults()
            #expect(loaded.targetLanguage == "zh-Hans")
            #expect(loaded.primaryModelId == 101)
            #expect(loaded.fallbackModelId == 202)
            #expect(loaded.promptStrategy == .hyMTOptimized)
            #expect(loaded.concurrencyDegree == 5)

            appModel.saveTranslationAgentDefaults(
                TranslationAgentDefaults(
                    targetLanguage: "",
                    primaryModelId: nil,
                    fallbackModelId: nil,
                    promptStrategy: .standard,
                    concurrencyDegree: 999
                )
            )

            let reset = appModel.loadTranslationAgentDefaults()
            #expect(reset.targetLanguage == AgentLanguageOption.english.code)
            #expect(reset.primaryModelId == nil)
            #expect(reset.fallbackModelId == nil)
            #expect(reset.promptStrategy == .standard)
            #expect(reset.concurrencyDegree == TranslationSettingsKey.concurrencyRange.upperBound)

            appModel.saveTranslationAgentDefaults(
                TranslationAgentDefaults(
                    targetLanguage: "en",
                    primaryModelId: nil,
                    fallbackModelId: nil,
                    promptStrategy: .standard,
                    concurrencyDegree: 0
                )
            )

            let clampedLow = appModel.loadTranslationAgentDefaults()
            #expect(clampedLow.concurrencyDegree == TranslationSettingsKey.concurrencyRange.lowerBound)
        }
    }

    @Test("Agent configuration snapshot normalizes stale translation model selections without rewriting defaults")
    @MainActor
    func agentConfigurationSnapshotNormalizesStaleTranslationModelSelectionsWithoutRewritingDefaults() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: TranslationTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel

            let keys = [
                TranslationSettingsKey.targetLanguage,
                TranslationSettingsKey.primaryModelId,
                TranslationSettingsKey.fallbackModelId,
                TranslationSettingsKey.promptStrategy,
                TranslationSettingsKey.concurrencyDegree
            ]
            let savedValues = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
            defer {
                for (key, value) in savedValues {
                    if let value {
                        UserDefaults.standard.set(value, forKey: key)
                    } else {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                }
            }

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

            appModel.saveTranslationAgentDefaults(
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

            let reloadedDefaults = appModel.loadTranslationAgentDefaults()
            #expect(reloadedDefaults.primaryModelId == modelId)
            #expect(reloadedDefaults.fallbackModelId == modelId)
            #expect(reloadedDefaults.promptStrategy == .hyMTOptimized)
        }
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
