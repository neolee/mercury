import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Database Manager Locking")
struct DatabaseManagerLockingTests {
    @Test("Concurrent writes on separate connections wait instead of failing fast")
    @MainActor
    func concurrentWritesWaitForLockRelease() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let managerA = try await MainActor.run {
            try DatabaseManager(path: dbPath)
        }
        let managerB = try await MainActor.run {
            try DatabaseManager(path: dbPath)
        }

        try await managerA.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS lock_probe (id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT NOT NULL)")
        }

        async let writerA: Void = managerA.write { db in
            try db.execute(sql: "INSERT INTO lock_probe (note) VALUES ('writer-a-start')")
            Thread.sleep(forTimeInterval: 1.2)
            try db.execute(sql: "INSERT INTO lock_probe (note) VALUES ('writer-a-end')")
        }

        try await Task.sleep(nanoseconds: 150_000_000)

        let writerBStart = Date()
        try await managerB.write { db in
            try db.execute(sql: "INSERT INTO lock_probe (note) VALUES ('writer-b')")
        }
        let writerBElapsed = Date().timeIntervalSince(writerBStart)

        try await writerA

        let (count, notes) = try await managerA.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lock_probe") ?? 0
            let notes = try String.fetchAll(db, sql: "SELECT note FROM lock_probe ORDER BY id ASC")
            return (count, notes)
        }

        #expect(count == 3)
        #expect(notes == ["writer-a-start", "writer-a-end", "writer-b"])
        #expect(writerBElapsed >= 0.5)
    }

    @Test("Read-only mode allows reads and rejects writes")
    @MainActor
    func readOnlyModeBehavior() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let writable = try await MainActor.run {
            try DatabaseManager(path: dbPath)
        }
        try await writable.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS read_only_probe (id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO read_only_probe (note) VALUES ('seed')")
        }

        let readOnly = try await MainActor.run {
            try DatabaseManager(path: dbPath, accessMode: .readOnly)
        }
        let count = try await readOnly.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM read_only_probe") ?? 0
        }
        #expect(count == 1)

        do {
            try await readOnly.write { db in
                try db.execute(sql: "INSERT INTO read_only_probe (note) VALUES ('should-fail')")
            }
            Issue.record("Expected read-only write to fail, but it succeeded.")
        } catch let error as DatabaseManagerError {
            #expect(error == .readOnlyWriteAttempt)
        }
    }

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-lock-tests-\(UUID().uuidString).sqlite")
            .path
    }
}
