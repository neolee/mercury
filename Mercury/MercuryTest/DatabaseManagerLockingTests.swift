import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Database Manager Locking")
struct DatabaseManagerLockingTests {
    @Test("Concurrent writes on separate connections wait instead of failing fast")
    @MainActor
    func concurrentWritesWaitForLockRelease() async throws {
        try await OnDiskDatabaseFixture.withFixture(prefix: "mercury-lock-tests") { fixture in
            let managerA = try fixture.makeDatabaseManager()
            let managerB = try fixture.makeDatabaseManager()

            try await managerA.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS lock_probe (id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT NOT NULL)")
            }

            // Signal from inside the write closure once the lock is held.
            let (lockAcquiredStream, lockAcquiredCont) = AsyncStream<Void>.makeStream()

            async let writerA: Void = managerA.write { db in
                try db.execute(sql: "INSERT INTO lock_probe (note) VALUES ('writer-a-start')")
                lockAcquiredCont.yield()  // Deterministic: lock is now held
                Thread.sleep(forTimeInterval: 1.0)
                try db.execute(sql: "INSERT INTO lock_probe (note) VALUES ('writer-a-end')")
            }

            // Wait until writer-a has confirmed it holds the write lock.
            var lockIter = lockAcquiredStream.makeAsyncIterator()
            _ = await lockIter.next()
            lockAcquiredCont.finish()

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
    }

    @Test("Read-only mode allows reads and rejects writes")
    @MainActor
    func readOnlyModeBehavior() async throws {
        try await OnDiskDatabaseFixture.withFixture(prefix: "mercury-lock-tests") { fixture in
            let writable = try fixture.makeDatabaseManager()
            try await writable.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS read_only_probe (id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO read_only_probe (note) VALUES ('seed')")
            }

            let readOnly = try fixture.makeDatabaseManager(accessMode: .readOnly)
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
    }
}
