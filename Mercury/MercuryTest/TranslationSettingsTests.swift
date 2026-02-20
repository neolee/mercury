import Foundation
import Testing
@testable import Mercury

@Suite("AI Translation Settings")
@MainActor
struct TranslationSettingsTests {
    @Test("Translation defaults persist and reload")
    func translationDefaultsPersistAndReload() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let appModel = AppModel(
            databaseManager: try DatabaseManager(path: dbPath),
            credentialStore: TranslationTestCredentialStore()
        )

        let keys = [
            "AI.Translation.DefaultTargetLanguage",
            "AI.Translation.PrimaryModelId",
            "AI.Translation.FallbackModelId"
        ]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

        appModel.saveTranslationAgentDefaults(
            TranslationAgentDefaults(
                targetLanguage: "zh-cn",
                primaryModelId: 101,
                fallbackModelId: 202
            )
        )

        let loaded = appModel.loadTranslationAgentDefaults()
        #expect(loaded.targetLanguage == "zh-Hans")
        #expect(loaded.primaryModelId == 101)
        #expect(loaded.fallbackModelId == 202)

        appModel.saveTranslationAgentDefaults(
            TranslationAgentDefaults(
                targetLanguage: "",
                primaryModelId: nil,
                fallbackModelId: nil
            )
        )

        let reset = appModel.loadTranslationAgentDefaults()
        #expect(reset.targetLanguage == "zh-Hans")
        #expect(reset.primaryModelId == nil)
        #expect(reset.fallbackModelId == nil)
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
