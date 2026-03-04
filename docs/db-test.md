# Database Test Lifecycle Plan

Date: 2026-03-04
Status: Proposed and intended to become the mandatory test contract

## 1. Goal

Mercury must eliminate database-test resource leaks permanently and replace ad hoc cleanup with one deterministic lifecycle model.

This document defines the only acceptable database test patterns for the project.

Success means:

1. Database tests leave no `.sqlite`, `-wal`, `-shm`, or temporary directories behind.
2. Test cleanup never depends on ARC timing or process exit.
3. New tests are structurally prevented from reintroducing file-lifecycle bugs.
4. Most database tests run in memory; on-disk tests are explicit exceptions.
5. Teardown order is standardized and testable.
6. New database tests use a small shared fixture/harness surface instead of copy-pasting path, setup, and cleanup code.

## 2. Problem Statement

Current test code frequently follows this pattern:

1. Build a path under `NSTemporaryDirectory()`.
2. Open `DatabaseManager(path: dbPath)`.
3. Sometimes construct `AppModel` or `SidebarCountStore` on top.
4. `defer { removeItem(atPath: dbPath) }`.

This is non-compliant for two independent reasons.

### 2.1 Wrong cleanup unit

`DatabaseManager` enables WAL for read-write connections, so SQLite may create:

- `db.sqlite`
- `db.sqlite-wal`
- `db.sqlite-shm`

Deleting only the main `.sqlite` file is not a complete cleanup strategy.

### 2.2 Wrong teardown timing

Some test owners outlive the test body in non-obvious ways:

- `AppModel` starts background work during initialization.
- `SidebarCountStore` owns a long-lived `ValueObservation`.
- Multiple `DatabaseManager` instances can keep separate connections open.

Deleting the file before all owners are shut down causes warnings such as `vnode unlinked while in use` and leaves residual files behind.

## 3. Root Cause Summary

The root problem is not test parallelism.

Parallel execution can amplify the symptoms, but it is not the primary fault domain. The primary fault domain is that database test resources are not managed as owned lifecycles.

The current codebase has two structural gaps:

1. Tests create on-disk databases directly instead of going through a shared fixture.
2. Production-facing owners that hold database work do not yet expose a deterministic test shutdown contract.

## 4. Design Principles

All future database test infrastructure must follow these principles.

### 4.1 Resource ownership is explicit

Every database used by a test must have one fixture object that owns:

- database location
- database manager creation
- higher-level owners created on top of it
- shutdown order
- final filesystem cleanup

### 4.1.1 Test ergonomics are part of the contract

The intended end state is not just safer cleanup. It is a simpler authoring model.

After this plan is implemented, a developer writing a new database test should only need to choose one of a small number of approved helpers, for example:

- `InMemoryDatabaseFixture`
- `OnDiskDatabaseFixture`
- `AppModelTestHarness`

Writing a new database test must not require:

- re-reading this document for routine setup
- copying a previous test as a setup template
- hand-rolling a database path
- hand-rolling cleanup logic
- guessing shutdown order

If a new test still needs those steps, the infrastructure is incomplete.

### 4.2 Cleanup happens at directory scope

For on-disk tests, the cleanup unit is the per-test temporary directory, never the main database file.

### 4.3 Teardown is ordered, not incidental

Cleanup must not rely on variable scope exit, ARC timing, or implicit deallocation side effects.

### 4.4 In-memory is the default

If a test does not verify file-path, multi-connection, read-only, WAL, lock waiting, or restart semantics, it must use an in-memory database.

### 4.5 On-disk is an opt-in capability

On-disk database usage requires an explicit reason that matches approved categories.

## 5. Mandatory Policy

This section is normative.

### 5.1 Allowed database test modes

Only two modes are allowed.

#### Mode A: In-memory database test

Use for:

- repository/query logic
- persistence semantics unrelated to file system behavior
- schema and migration assertions that do not require filesystem effects
- `AppModel` behavior that only needs a database backend, not a database file

This is the default mode.

#### Mode B: On-disk database test

Use only for:

- multiple simultaneous connections to the same database file
- read-only open against an existing database file
- lock waiting and busy-timeout behavior
- WAL-specific or sidecar-file behavior
- path-sensitive behavior
- restart/reopen semantics that require a real file

If a test does not clearly fit one of these categories, it must not use an on-disk database.

### 5.2 Forbidden patterns

The following patterns are banned for database tests.

1. Hand-written `temporaryDatabasePath()` helpers that return `...uuid.sqlite`.
2. `defer { try? FileManager.default.removeItem(atPath: dbPath) }` for database cleanup.
3. Creating an on-disk database outside a shared fixture or harness.
4. Deleting only the `.sqlite` file for a WAL-backed database.
5. Relying on `deinit` timing as the primary cleanup mechanism.
6. Constructing `AppModel` or `SidebarCountStore` in tests without a deterministic shutdown path.
7. Copy-pasting lifecycle boilerplate from an existing test instead of using the shared fixture or harness API.

### 5.3 Required teardown order

For every on-disk database test, teardown must execute in this order:

1. stop observers, subscriptions, and background tasks
2. shut down higher-level owners such as `AppModel` and `SidebarCountStore`
3. release all `DatabaseManager` instances
4. delete the per-test temporary directory
5. assert that deletion succeeded

No step may be skipped.

## 6. Required Test Infrastructure

Mercury should standardize on a small shared test infrastructure surface.

The purpose of this infrastructure is twofold:

1. enforce lifecycle correctness
2. make compliant tests the easiest tests to write

### 6.1 `TestTemporaryDirectory`

Responsibility:

- create a unique per-test directory
- expose stable paths within it
- delete the whole directory at teardown
- fail loudly if cleanup does not succeed

Required properties:

- directory name includes suite/test identity when possible
- location is under `NSTemporaryDirectory()/MercuryTests/...`
- one fixture instance owns one directory

### 6.2 `InMemoryDatabaseFixture`

Responsibility:

- create an in-memory `DatabaseManager`
- provide deterministic teardown hooks
- host optional seed helpers

Required usage:

- default for data-layer tests
- preferred even for many `AppModel` tests once `AppModel` shutdown becomes explicit

### 6.3 `OnDiskDatabaseFixture`

Responsibility:

- create one per-test temporary directory
- place the database file inside it
- expose the canonical database path
- own and tear down all created database managers
- remove the full directory only after all owners are shut down

Required rule:

- tests must never access raw cleanup directly; cleanup is fixture-owned

### 6.4 `AppModelTestHarness`

Responsibility:

- compose database fixture + credential store + `AppModel`
- expose deterministic `shutdown()` for tests
- own any additional stores created on top of the same database
- ensure teardown order is followed consistently

This harness should become the only approved path for database-backed `AppModel` tests.

### 6.5 Small approved surface area

The shared infrastructure should stay intentionally small.

For most new tests, authors should be able to start from one of these entry points without reading implementation details:

1. `InMemoryDatabaseFixture` for data/query/persistence tests
2. `OnDiskDatabaseFixture` for real-file semantics
3. `AppModelTestHarness` for `AppModel`-backed scenarios

If common testing scenarios still require additional bespoke helpers inside individual test files, the shared API surface should be expanded until that is no longer necessary.

## 7. Required Production Hooks for Testability

To make the contract enforceable, some production-facing owners need explicit lifecycle APIs.

### 7.1 `DatabaseManager`

Required capability:

- supported creation of an in-memory database for tests and future internal uses

Rationale:

Without this, too many pure logic tests are forced onto the filesystem.

### 7.2 `SidebarCountStore`

Required capability:

- explicit observation shutdown, such as `stopObservation()` or equivalent owner-controlled invalidation

Rationale:

Observation lifetime must be terminated intentionally during teardown.

### 7.3 `AppModel`

Required capability:

- explicit test-friendly shutdown for background work started during initialization
- startup task handles must be owned and cancellable or awaitable

Rationale:

`AppModel` currently starts asynchronous work during initialization. Tests need a deterministic way to end that work before database cleanup.

### 7.4 Optional but recommended: lifecycle protocol

Consider a small internal protocol for test-owned resources, for example:

- `shutdownForTesting()`
- `tearDownOwnedResources()`

The exact naming is less important than making shutdown explicit and consistent.

## 8. Approved Test Patterns

### 8.1 Default pattern for data/query tests

1. create `InMemoryDatabaseFixture`
2. seed data through fixture manager
3. run assertions
4. call fixture teardown

### 8.2 Default pattern for `AppModel` tests

1. create `AppModelTestHarness` using in-memory database unless disk is required
2. run assertions through `harness.appModel`
3. call `await harness.shutdown()`
4. allow fixture to clean underlying resources

### 8.3 Default pattern for lock/read-only tests

1. create `OnDiskDatabaseFixture`
2. create the required multiple managers from the fixture
3. run lock/read-only assertions
4. release managers through fixture shutdown
5. delete the directory through fixture cleanup

## 9. Migration Rules for Existing Tests

This section classifies current tests by migration target.

### 9.1 Priority P0: high-risk tests that must move first

These tests currently combine on-disk databases with long-lived owners such as `AppModel` or `SidebarCountStore`.

- `Mercury/MercuryTest/TranslationSettingsTests.swift`
- `Mercury/MercuryTest/UsageReportQueryTests.swift`
- `Mercury/MercuryTest/LLMUsageRetentionTests.swift`
- `Mercury/MercuryTest/SummaryStorageTests.swift`
- `Mercury/MercuryTest/TranslationStoragePersistenceTests.swift`
- `Mercury/MercuryTest/TranslationStorageQueryTests.swift`
- `Mercury/MercuryTest/SidebarCountStoreTests.swift`

Required migration:

- stop hand-building database paths
- move to shared harness/fixture
- add deterministic shutdown before cleanup
- prefer in-memory unless the test explicitly needs disk

### 9.2 Priority P1: tests that likely still need on-disk fixture

- `Mercury/MercuryTest/DatabaseManagerLockingTests.swift`
- read-only portions of `Mercury/MercuryTest/EntryStoreStarredTests.swift`

Required migration:

- keep them on disk
- move them to per-test directory fixtures
- ensure all managers are released before cleanup

### 9.3 Priority P2: tests that should be moved to in-memory

These tests appear to validate data behavior, not file semantics.

- `Mercury/MercuryTest/LLMUsageEventPersistenceTests.swift`
- `Mercury/MercuryTest/TagQueryTests.swift`
- `Mercury/MercuryTest/EntryStoreStarredTests.swift` except real read-only file cases
- `Mercury/MercuryTest/TaggingExecutionTests.swift`
- `Mercury/MercuryTest/TagsDatabaseTests.swift`
- `Mercury/MercuryTest/SyncServiceStarredInvariantTests.swift`
- `Mercury/MercuryTest/TranslationSchemaTests.swift`
- `Mercury/MercuryTest/TagAssignmentTests.swift`

Required migration:

- move to `InMemoryDatabaseFixture`
- remove all path helper functions
- remove all file deletion code

## 10. Enforcement Rules for Future Tests

This plan is only useful if it becomes enforceable.

### 10.1 Code review rules

Any new database test must answer these questions explicitly:

1. Why is this not using the shared fixture?
2. Why is this not using an in-memory database?
3. If on-disk: what exact filesystem behavior is being validated?
4. What explicit shutdown path exists before cleanup?

If the author cannot answer these clearly, the test is non-compliant.

### 10.2 Static hygiene rules

The test target should eventually eliminate or ban these patterns:

- direct `NSTemporaryDirectory()` usage for database files
- `removeItem(atPath: dbPath)` in database tests
- local helpers that return `*.sqlite` temp paths

A lightweight lint step or grep-based CI guard is acceptable if needed.

### 10.3 Shared fixture monopoly

All new database-backed tests should use the shared fixture modules. Direct filesystem lifecycle management in individual tests should be treated as a contract violation.

### 10.4 Documentation is not the primary user interface

This document defines policy and architecture. It is not the intended day-to-day setup guide for routine database tests.

The primary developer interface must be the shared fixture and harness APIs. Documentation should only be needed for:

- understanding the policy
- reviewing exceptional cases
- extending the infrastructure
- diagnosing failures

## 11. Rollout Plan

### Step 1: establish infrastructure

Implement:

- `TestTemporaryDirectory`
- `InMemoryDatabaseFixture`
- `OnDiskDatabaseFixture`
- `AppModelTestHarness`

Do not migrate tests before the infrastructure exists.

### Step 2: add explicit production shutdown hooks

Implement:

- in-memory `DatabaseManager` creation path
- explicit `SidebarCountStore` observation shutdown
- explicit `AppModel` shutdown for startup/background work

This step makes deterministic teardown possible.

### Step 3: migrate P0 suites

Migrate the high-risk suites first and use them as the acceptance baseline for the new lifecycle model.

### Step 4: migrate P1 and P2 suites

Keep only a minimal set of on-disk tests.

### Step 5: add enforcement

Add a lightweight guard so new direct database temp-file patterns cannot re-enter the codebase.

## 12. Acceptance Criteria

This work is not complete until all of the following are true.

1. No database test deletes only the `.sqlite` file.
2. No database test owns raw temp-db cleanup logic directly.
3. High-risk `AppModel` and `SidebarCountStore` suites run without SQLite unlink warnings.
4. Running the targeted database test suites leaves no leaked SQLite artifacts under the Mercury test temp root.
5. The remaining on-disk tests are justified by explicit file-behavior requirements.
6. New database tests have one obvious approved path and do not need bespoke lifecycle decisions.

## 13. Non-Goals

This plan does not require:

- changing production runtime database policy outside testability hooks
- removing all on-disk database tests
- changing unrelated temporary-directory tests such as prompt-template directory tests

## 14. Decision Summary

Mercury should adopt the following permanent rule set:

1. in-memory is the default for database tests
2. on-disk is allowed only for explicit file semantics
3. on-disk cleanup is directory-based, never file-based
4. all database tests use shared fixtures or harnesses
5. owners with background work or observation must support explicit shutdown
6. future tests that bypass this model are non-compliant by definition
