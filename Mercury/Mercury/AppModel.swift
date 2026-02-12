//
//  AppModel.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let database: DatabaseManager
    let feedStore: FeedStore
    let entryStore: EntryStore
    let contentStore: ContentStore
    let taskCenter: TaskCenter
    let syncService: SyncService
    let jobRunner = JobRunner()
    let taskQueue: TaskQueue
    let feedCRUDUseCase: FeedCRUDUseCase
    let readerBuildUseCase: ReaderBuildUseCase
    let feedSyncUseCase: FeedSyncUseCase
    let importOPMLUseCase: ImportOPMLUseCase
    let exportOPMLUseCase: ExportOPMLUseCase
    let bootstrapUseCase: BootstrapUseCase

    let lastSyncKey = "LastSyncAt"
    let syncThreshold: TimeInterval = 15 * 60
    var reservedFeedSyncIDs: Set<Int64> = []

    @Published var isReady: Bool = false
    @Published var feedCount: Int = 0
    @Published var entryCount: Int = 0
    @Published var totalUnreadCount: Int = 0
    @Published var lastSyncAt: Date?
    @Published var syncState: SyncState = .idle
    @Published var bootstrapState: BootstrapState = .idle
    @Published var backgroundDataVersion: Int = 0

    init() {
        do {
            database = try DatabaseManager()
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }

        feedStore = FeedStore(db: database)
        entryStore = EntryStore(db: database)
        contentStore = ContentStore(db: database)
        taskQueue = TaskQueue(maxConcurrentTasks: 2)
        taskCenter = TaskCenter(queue: taskQueue)
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
        lastSyncAt = loadLastSyncAt()
        isReady = true
    }

    @discardableResult
    func enqueueTask(
        kind: AppTaskKind,
        title: String,
        priority: AppTaskPriority = .utility,
        operation: @escaping (TaskProgressReporter) async throws -> Void
    ) async -> UUID {
        await taskCenter.enqueue(
            kind: kind,
            title: title,
            priority: priority,
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
