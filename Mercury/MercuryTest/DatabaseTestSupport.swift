import Foundation
@testable import Mercury

private enum DatabaseTestSupportError: Error {
    case cleanupFailed(String)
}

final class TestUserDefaultsSuite {
    let suiteName: String
    let defaults: UserDefaults

    init(prefix: String = "MercuryTests") {
        suiteName = "\(prefix).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Failed to create test UserDefaults suite \(suiteName)")
        }
        self.defaults = defaults
        defaults.removePersistentDomain(forName: suiteName)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

final class TestTemporaryDirectory {
    let url: URL

    private let fileManager: FileManager
    private var isCleanedUp = false

    init(prefix: String, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MercuryTests", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        url = root.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func childURL(named name: String, isDirectory: Bool = false) -> URL {
        url.appendingPathComponent(name, isDirectory: isDirectory)
    }

    func cleanup() throws {
        guard isCleanedUp == false else { return }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        guard fileManager.fileExists(atPath: url.path) == false else {
            throw DatabaseTestSupportError.cleanupFailed(url.path)
        }
        isCleanedUp = true
    }
}

final class InMemoryDatabaseFixture {
    private var databaseManager: DatabaseManager?

    var database: DatabaseManager {
        guard let databaseManager else {
            preconditionFailure("Database fixture has already been shut down.")
        }
        return databaseManager
    }

    init(accessMode: DatabaseAccessMode = .readWrite) throws {
        databaseManager = try DatabaseManager(inMemory: accessMode)
    }

    func shutdown() async throws {
        databaseManager = nil
        await Task.yield()
    }

    static func withFixture<Result>(
        accessMode: DatabaseAccessMode = .readWrite,
        _ body: (InMemoryDatabaseFixture) async throws -> Result
    ) async throws -> Result {
        let fixture = try InMemoryDatabaseFixture(accessMode: accessMode)
        do {
            let result = try await body(fixture)
            try await fixture.shutdown()
            return result
        } catch {
            try? await fixture.shutdown()
            throw error
        }
    }
}

final class OnDiskDatabaseFixture {
    let temporaryDirectory: TestTemporaryDirectory
    let databaseURL: URL

    private var databaseManagers: [DatabaseManager] = []

    init(prefix: String = "mercury-db-test", databaseFileName: String = "db.sqlite") throws {
        temporaryDirectory = try TestTemporaryDirectory(prefix: prefix)
        databaseURL = temporaryDirectory.childURL(named: databaseFileName)
    }

    func makeDatabaseManager(accessMode: DatabaseAccessMode = .readWrite) throws -> DatabaseManager {
        let manager = try DatabaseManager(path: databaseURL.path, accessMode: accessMode)
        databaseManagers.append(manager)
        return manager
    }

    func shutdown() async throws {
        databaseManagers.removeAll()
        await Task.yield()
        try temporaryDirectory.cleanup()
    }

    static func withFixture<Result>(
        prefix: String = "mercury-db-test",
        databaseFileName: String = "db.sqlite",
        _ body: (OnDiskDatabaseFixture) async throws -> Result
    ) async throws -> Result {
        let fixture = try OnDiskDatabaseFixture(prefix: prefix, databaseFileName: databaseFileName)
        do {
            let result = try await body(fixture)
            try await fixture.shutdown()
            return result
        } catch {
            try? await fixture.shutdown()
            throw error
        }
    }
}

@MainActor
final class AppModelTestHarness {
    private var inMemoryFixture: InMemoryDatabaseFixture?
    private var onDiskFixture: OnDiskDatabaseFixture?
    private var storedAppModel: AppModel?

    var appModel: AppModel {
        guard let storedAppModel else {
            preconditionFailure("AppModel harness has already been shut down.")
        }
        return storedAppModel
    }

    var database: DatabaseManager {
        appModel.database
    }

    private init(
        inMemoryFixture: InMemoryDatabaseFixture,
        credentialStore: CredentialStore,
        agentSettingsDefaults: UserDefaults
    ) throws {
        self.inMemoryFixture = inMemoryFixture
        storedAppModel = AppModel(
            databaseManager: inMemoryFixture.database,
            credentialStore: credentialStore,
            agentSettingsDefaults: agentSettingsDefaults
        )
    }

    private init(
        onDiskFixture: OnDiskDatabaseFixture,
        credentialStore: CredentialStore,
        agentSettingsDefaults: UserDefaults
    ) throws {
        self.onDiskFixture = onDiskFixture
        storedAppModel = AppModel(
            databaseManager: try onDiskFixture.makeDatabaseManager(),
            credentialStore: credentialStore,
            agentSettingsDefaults: agentSettingsDefaults
        )
    }

    static func inMemory(
        credentialStore: CredentialStore,
        agentSettingsDefaults: UserDefaults = .standard
    ) throws -> AppModelTestHarness {
        try AppModelTestHarness(
            inMemoryFixture: InMemoryDatabaseFixture(),
            credentialStore: credentialStore,
            agentSettingsDefaults: agentSettingsDefaults
        )
    }

    static func onDisk(
        prefix: String = "mercury-app-model-test",
        credentialStore: CredentialStore,
        agentSettingsDefaults: UserDefaults = .standard
    ) throws -> AppModelTestHarness {
        try AppModelTestHarness(
            onDiskFixture: OnDiskDatabaseFixture(prefix: prefix),
            credentialStore: credentialStore,
            agentSettingsDefaults: agentSettingsDefaults
        )
    }

    func shutdown() async throws {
        if let storedAppModel {
            await storedAppModel.shutdownForTesting()
        }
        storedAppModel = nil

        if let inMemoryFixture {
            try await inMemoryFixture.shutdown()
            self.inMemoryFixture = nil
        }
        if let onDiskFixture {
            try await onDiskFixture.shutdown()
            self.onDiskFixture = nil
        }
    }

    static func withInMemory<Result>(
        credentialStore: CredentialStore,
        agentSettingsDefaults: UserDefaults = .standard,
        _ body: @MainActor (AppModelTestHarness) async throws -> Result
    ) async throws -> Result {
        let harness = try AppModelTestHarness.inMemory(
            credentialStore: credentialStore,
            agentSettingsDefaults: agentSettingsDefaults
        )
        do {
            let result = try await body(harness)
            try await harness.shutdown()
            return result
        } catch {
            try? await harness.shutdown()
            throw error
        }
    }

    static func withOnDisk<Result>(
        prefix: String = "mercury-app-model-test",
        credentialStore: CredentialStore,
        agentSettingsDefaults: UserDefaults = .standard,
        _ body: @MainActor (AppModelTestHarness) async throws -> Result
    ) async throws -> Result {
        let harness = try AppModelTestHarness.onDisk(
            prefix: prefix,
            credentialStore: credentialStore,
            agentSettingsDefaults: agentSettingsDefaults
        )
        do {
            let result = try await body(harness)
            try await harness.shutdown()
            return result
        } catch {
            try? await harness.shutdown()
            throw error
        }
    }
}
