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

    @Published private(set) var isReady: Bool = false

    init() {
        do {
            database = try DatabaseManager()
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }

        feedStore = FeedStore(db: database)
        entryStore = EntryStore(db: database)
        contentStore = ContentStore(db: database)
        isReady = true
    }
}
