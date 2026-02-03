//
//  AppStore.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
    let database: DatabaseManager
    let feedStore: FeedStore
    let entryStore: EntryStore
    let contentStore: ContentStore
    private let syncService: SyncService

    @Published private(set) var isReady: Bool = false
    @Published private(set) var feedCount: Int = 0
    @Published private(set) var entryCount: Int = 0
    @Published private(set) var bootstrapState: BootstrapState = .idle

    init() {
        do {
            database = try DatabaseManager()
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }

        feedStore = FeedStore(db: database)
        entryStore = EntryStore(db: database)
        contentStore = ContentStore(db: database)
        syncService = SyncService(db: database)
        isReady = true
    }

    func bootstrapIfNeeded() async {
        guard bootstrapState == .idle else { return }
        bootstrapState = .importing

        do {
            try await syncService.bootstrapIfNeeded(limit: 10)
            await feedStore.loadAll()
            await entryStore.loadAll(for: nil)
            feedCount = feedStore.feeds.count
            entryCount = entryStore.entries.count
            bootstrapState = .ready
        } catch {
            bootstrapState = .failed(error.localizedDescription)
        }
    }
}

enum BootstrapState: Equatable {
    case idle
    case importing
    case ready
    case failed(String)
}
