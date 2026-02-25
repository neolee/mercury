//
//  AppModel.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Combine
import Foundation
import GRDB

@MainActor
final class AppModel: ObservableObject {
    private static var sharedDefaultDatabaseManager: DatabaseManager?

    let database: DatabaseManager
    let feedStore: FeedStore
    let entryStore: EntryStore
    let contentStore: ContentStore
    let taskCenter: TaskCenter
    let agentRuntimeEngine: AgentRuntimeEngine
    let syncService: SyncService
    let jobRunner = JobRunner()
    let taskQueue: TaskQueue
    let feedCRUDUseCase: FeedCRUDUseCase
    let readerBuildUseCase: ReaderBuildUseCase
    let feedSyncUseCase: FeedSyncUseCase
    let importOPMLUseCase: ImportOPMLUseCase
    let exportOPMLUseCase: ExportOPMLUseCase
    let bootstrapUseCase: BootstrapUseCase
    let credentialStore: CredentialStore
    let agentProviderValidationUseCase: AgentProviderValidationUseCase

    let lastSyncKey = "LastSyncAt"
    let syncFeedConcurrencyKey = "SyncFeedConcurrency"
    let syncThreshold: TimeInterval = 15 * 60
    let defaultSyncFeedConcurrency: Int = 6
    let syncFeedConcurrencyRange: ClosedRange<Int> = 2...10
    var reservedFeedSyncIDs: Set<Int64> = []

    var syncFeedConcurrency: Int {
        let stored = UserDefaults.standard.object(forKey: syncFeedConcurrencyKey) as? Int
        return clampSyncFeedConcurrency(stored ?? defaultSyncFeedConcurrency)
    }

    @Published var isReady: Bool = false
    @Published var feedCount: Int = 0
    @Published var entryCount: Int = 0
    @Published var totalUnreadCount: Int = 0
    @Published var lastSyncAt: Date?
    @Published var syncState: SyncState = .idle
    @Published var bootstrapState: BootstrapState = .idle
    @Published var backgroundDataVersion: Int = 0
    @Published var isSummaryAgentAvailable: Bool = false
    @Published var isTranslationAgentAvailable: Bool = false
    @Published var startupGateState: StartupGateState = .migratingDatabase

    init(databaseManager: DatabaseManager, credentialStore: CredentialStore) {
        ReaderThemeDebugValidation.validateContracts()
        database = databaseManager
        feedStore = FeedStore(db: database)
        entryStore = EntryStore(db: database)
        contentStore = ContentStore(db: database)
        taskQueue = TaskQueue(
            maxConcurrentTasks: 5,
            perKindConcurrencyLimits: [.summary: 1, .translation: 1]
        )
        taskCenter = TaskCenter(queue: taskQueue)
        agentRuntimeEngine = AgentRuntimeEngine(
            policy: AgentRuntimePolicy(
                perTaskConcurrencyLimit: [
                    .summary: 1,
                    .translation: 1,
                    .tagging: 2
                ]
            )
        )
        syncService = SyncService(db: database, jobRunner: jobRunner)
        let feedInputValidator = FeedInputValidator(database: database)
        feedCRUDUseCase = FeedCRUDUseCase(
            database: database,
            syncService: syncService,
            validator: feedInputValidator
        )
        readerBuildUseCase = ReaderBuildUseCase(
            contentStore: contentStore,
            jobRunner: jobRunner
        )
        feedSyncUseCase = FeedSyncUseCase(database: database, syncService: syncService)
        importOPMLUseCase = ImportOPMLUseCase(
            database: database,
            syncService: syncService,
            feedSyncUseCase: feedSyncUseCase
        )
        exportOPMLUseCase = ExportOPMLUseCase(database: database)
        bootstrapUseCase = BootstrapUseCase(
            database: database,
            feedSyncUseCase: feedSyncUseCase
        )
        self.credentialStore = credentialStore
        agentProviderValidationUseCase = AgentProviderValidationUseCase(
            provider: AgentLLMProvider(),
            credentialStore: self.credentialStore
        )
        lastSyncAt = loadLastSyncAt()
        isReady = true
        Task {
            await completeStartupMigrationGate()
            _ = await runStartupLLMUsageRetentionCleanupIfReady()
            await refreshAgentAvailability()
        }
    }

    convenience init(databaseManager: DatabaseManager) {
        self.init(
            databaseManager: databaseManager,
            credentialStore: KeychainCredentialStore()
        )
    }

    convenience init() {
        do {
            let databaseManager = try Self.makeDefaultDatabaseManager()
            self.init(databaseManager: databaseManager)
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    private static func makeDefaultDatabaseManager() throws -> DatabaseManager {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let path = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("mercury-xctest-host-\(ProcessInfo.processInfo.processIdentifier).sqlite")
                .path
            return try DatabaseManager(path: path)
        }

        if let sharedDefaultDatabaseManager {
            return sharedDefaultDatabaseManager
        }

        do {
            let manager = try DatabaseManager()
            sharedDefaultDatabaseManager = manager
            return manager
        } catch {
            guard isDatabaseLockError(error) else {
                throw error
            }
            let defaultPath = try DatabaseManager.defaultDatabaseURL().path
            let manager = try openReadOnlyWithRetry(path: defaultPath)
            sharedDefaultDatabaseManager = manager
            return manager
        }
    }

    private static func openReadOnlyWithRetry(path: String, attempts: Int = 5, delayNanoseconds: UInt64 = 300_000_000) throws -> DatabaseManager {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try DatabaseManager(path: path, accessMode: .readOnly)
            } catch {
                lastError = error
                if isDatabaseLockError(error), attempt < attempts {
                    Thread.sleep(forTimeInterval: Double(delayNanoseconds) / 1_000_000_000.0)
                    continue
                }
                throw error
            }
        }
        if let lastError {
            throw lastError
        }
        throw NSError(
            domain: "Mercury.AppModel",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to open read-only database after retries."]
        )
    }

    private static func isDatabaseLockError(_ error: Error) -> Bool {
        if let dbError = error as? DatabaseError {
            let resultCode = dbError.resultCode
            if resultCode == .SQLITE_BUSY || resultCode == .SQLITE_LOCKED {
                return true
            }
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("database is locked") || message.contains("database is busy")
    }

    @discardableResult
    func enqueueTask(
        taskId: UUID? = nil,
        kind: AppTaskKind,
        title: String,
        priority: AppTaskPriority = .utility,
        executionTimeout: TimeInterval? = nil,
        operation: @escaping (TaskProgressReporter) async throws -> Void
    ) async -> UUID {
        await taskCenter.enqueue(
            taskId: taskId,
            kind: kind,
            title: title,
            priority: priority,
            executionTimeout: executionTimeout,
            operation: operation
        )
    }

    func cancelTask(_ taskId: UUID) async {
        await taskCenter.cancel(taskId: taskId)
    }

    func reportUserError(title: String, message: String) {
        taskCenter.reportUserError(title: title, message: message)
    }

    func reportDebugIssue(title: String, detail: String, category: DebugIssueCategory = .general) {
        taskCenter.reportDebugIssue(title: title, detail: detail, category: category)
    }

    func setSyncFeedConcurrency(_ value: Int) {
        let clamped = clampSyncFeedConcurrency(value)
        UserDefaults.standard.set(clamped, forKey: syncFeedConcurrencyKey)
    }

    private func clampSyncFeedConcurrency(_ value: Int) -> Int {
        min(max(value, syncFeedConcurrencyRange.lowerBound), syncFeedConcurrencyRange.upperBound)
    }

    func completeStartupMigrationGate() async {
        guard startupGateState == .migratingDatabase else { return }
        do {
            _ = try await database.read { _ in true }
            startupGateState = .ready
        } catch {
            let message = error.localizedDescription
            startupGateState = .failed(message)
            reportDebugIssue(
                title: "Startup Migration Gate Failed",
                detail: [
                    "phase=migratingDatabase",
                    "error=\(message)"
                ].joined(separator: "\n"),
                category: .task
            )
        }
    }

    func waitForStartupAutomationReady() async -> Bool {
        while true {
            switch startupGateState {
            case .ready:
                return true
            case .failed:
                return false
            case .migratingDatabase:
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}

enum StartupGateState: Equatable {
    case migratingDatabase
    case ready
    case failed(String)
}

enum FeedEditError: LocalizedError {
    case invalidURL
    case duplicateFeed
    case insecureScheme

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Please enter a valid feed URL."
        case .duplicateFeed:
            return "This feed already exists."
        case .insecureScheme:
            return "Only HTTPS feeds are supported."
        }
    }
}

enum BootstrapState: Equatable {
    case idle
    case importing
    case ready
    case failed(String)
}

enum SyncState: Equatable {
    case idle
    case syncing
    case failed(String)
}
