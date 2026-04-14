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

            let lockAcquired = DispatchSemaphore(value: 0)
            let releaseWriterA = DispatchSemaphore(value: 0)
            let writerBState = WriterBState()
            let clock = ContinuousClock()

            let writerA = Task.detached { [managerA] in
                try await managerA.write { db in
                    try db.execute(sql: "INSERT INTO lock_probe (note) VALUES ('writer-a-start')")
                    lockAcquired.signal()
                    _ = releaseWriterA.wait(timeout: .now() + 5)
                    try db.execute(sql: "INSERT INTO lock_probe (note) VALUES ('writer-a-end')")
                }
            }

            try await Self.waitUntil(
                message: "Timed out waiting for writer A to acquire the database write lock"
            ) {
                lockAcquired.wait(timeout: .now()) == .success
            }

            let writerBTask = Task.detached { [managerB] in
                let start = clock.now
                try await managerB.write { db in
                    try db.execute(sql: "INSERT INTO lock_probe (note) VALUES ('writer-b')")
                }
                let elapsed = start.duration(to: clock.now)
                await writerBState.markFinished()
                return elapsed
            }

            try await Task.sleep(for: .milliseconds(150))
            #expect(await writerBState.isFinished == false)

            releaseWriterA.signal()
            let writerBElapsed = try await writerBTask.value
            try await writerA.value

            let (count, notes) = try await managerA.read { db in
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lock_probe") ?? 0
                let notes = try String.fetchAll(db, sql: "SELECT note FROM lock_probe ORDER BY id ASC")
                return (count, notes)
            }

            #expect(count == 3)
            #expect(notes == ["writer-a-start", "writer-a-end", "writer-b"])
            #expect(writerBElapsed >= .milliseconds(150))
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

private actor WriterBState {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}

private extension DatabaseManagerLockingTests {
    @MainActor
    static func waitUntil(
        iterations: Int = 100,
        interval: Duration = .milliseconds(10),
        message: String,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<iterations {
            if condition() {
                return
            }
            try await Task.sleep(for: interval)
        }

        fatalError(message)
    }
}
