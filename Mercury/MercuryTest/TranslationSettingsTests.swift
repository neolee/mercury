import Foundation
import Testing
@testable import Mercury

@Suite("Translation Settings")
struct TranslationSettingsTests {
    @Test("Translation defaults persist and reload")
    @MainActor
    func translationDefaultsPersistAndReload() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let appModel = AppModel(
            databaseManager: try DatabaseManager(path: dbPath),
            credentialStore: TranslationTestCredentialStore()
        )

        let keys = [
            "Agent.Translation.DefaultTargetLanguage",
            "Agent.Translation.PrimaryModelId",
            "Agent.Translation.FallbackModelId",
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
                concurrencyDegree: 5
            )
        )

        let loaded = appModel.loadTranslationAgentDefaults()
        #expect(loaded.targetLanguage == "zh-Hans")
        #expect(loaded.primaryModelId == 101)
        #expect(loaded.fallbackModelId == 202)
        #expect(loaded.concurrencyDegree == 5)

        appModel.saveTranslationAgentDefaults(
            TranslationAgentDefaults(
                targetLanguage: "",
                primaryModelId: nil,
                fallbackModelId: nil,
                concurrencyDegree: 999
            )
        )

        let reset = appModel.loadTranslationAgentDefaults()
        #expect(reset.targetLanguage == "zh-Hans")
        #expect(reset.primaryModelId == nil)
        #expect(reset.fallbackModelId == nil)
        #expect(reset.concurrencyDegree == TranslationSettingsKey.concurrencyRange.upperBound)

        appModel.saveTranslationAgentDefaults(
            TranslationAgentDefaults(
                targetLanguage: "en",
                primaryModelId: nil,
                fallbackModelId: nil,
                concurrencyDegree: 0
            )
        )

        let clampedLow = appModel.loadTranslationAgentDefaults()
        #expect(clampedLow.concurrencyDegree == TranslationSettingsKey.concurrencyRange.lowerBound)
    }

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-translation-settings-tests-\(UUID().uuidString).sqlite")
            .path
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
