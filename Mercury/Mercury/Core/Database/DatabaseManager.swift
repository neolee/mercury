//
//  DatabaseManager.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Foundation
import GRDB

enum DatabaseAccessMode: Sendable {
    case readWrite
    case readOnly
}

enum DatabaseManagerError: LocalizedError, Equatable {
    case readOnlyWriteAttempt
    case duplicatePrimaryDatabaseInstance

    var errorDescription: String? {
        switch self {
        case .readOnlyWriteAttempt:
            return "Database is opened in read-only mode; write operation is unavailable."
        case .duplicatePrimaryDatabaseInstance:
            return "Primary database is already opened by another DatabaseManager instance in this process."
        }
    }
}

final class DatabaseManager {
    let dbQueue: DatabaseQueue
    let accessMode: DatabaseAccessMode
    private let queue: DispatchQueue
    private let primaryDatabasePathToken: String?
    private static let busyTimeoutSeconds: TimeInterval = 5
    private static let primaryDatabaseRegistryLock = NSLock()
    private static var activePrimaryDatabasePaths: Set<String> = []

    init(path: String? = nil, accessMode: DatabaseAccessMode = .readWrite) throws {
        self.accessMode = accessMode
        let dbPath: String
        if let path {
            dbPath = path
        } else {
            dbPath = try Self.defaultDatabaseURL().path
        }

        let standardizedPath = NSString(string: dbPath).standardizingPath
        let primaryPathToken: String?
        if try Self.isPrimaryDatabasePath(standardizedPath) {
            try Self.registerPrimaryDatabasePath(standardizedPath)
            primaryPathToken = standardizedPath
        } else {
            primaryPathToken = nil
        }
        self.primaryDatabasePathToken = primaryPathToken

        do {
            let configuration = Self.makeConfiguration(accessMode: accessMode)
            dbQueue = try DatabaseQueue(path: standardizedPath, configuration: configuration)
            queue = DispatchQueue(label: "Mercury.Database")
        } catch {
            if let primaryPathToken {
                Self.unregisterPrimaryDatabasePath(primaryPathToken)
            }
            throw error
        }

        if accessMode == .readWrite {
            try migrator.migrate(dbQueue)
        }
    }

    deinit {
        if let primaryDatabasePathToken {
            Self.unregisterPrimaryDatabasePath(primaryDatabasePathToken)
        }
    }

    static func defaultDatabaseURL() throws -> URL {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = appSupport.appendingPathComponent("Mercury", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("mercury.sqlite")
    }

    private static func makeConfiguration(accessMode: DatabaseAccessMode) -> Configuration {
        var configuration = Configuration()
        configuration.busyMode = .timeout(busyTimeoutSeconds)
        if accessMode == .readWrite {
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
        } else {
            configuration.readonly = true
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
        }
        return configuration
    }

    private static func isPrimaryDatabasePath(_ path: String) throws -> Bool {
        let primaryPath = try defaultDatabaseURL().path
        return NSString(string: primaryPath).standardizingPath == path
    }

    private static func registerPrimaryDatabasePath(_ path: String) throws {
        primaryDatabaseRegistryLock.lock()
        defer { primaryDatabaseRegistryLock.unlock() }
        guard activePrimaryDatabasePaths.contains(path) == false else {
            throw DatabaseManagerError.duplicatePrimaryDatabaseInstance
        }
        activePrimaryDatabasePaths.insert(path)
    }

    private static func unregisterPrimaryDatabasePath(_ path: String) {
        primaryDatabaseRegistryLock.lock()
        defer { primaryDatabaseRegistryLock.unlock() }
        activePrimaryDatabasePaths.remove(path)
    }

    func read<T>(_ block: @escaping (Database) throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let value = try self.dbQueue.read(block)
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func write<T>(_ block: @escaping (Database) throws -> T) async throws -> T {
        guard accessMode == .readWrite else {
            throw DatabaseManagerError.readOnlyWriteAttempt
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let value = try self.dbQueue.write(block)
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
