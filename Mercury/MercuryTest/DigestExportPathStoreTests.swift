import Darwin
import Foundation
import Testing
@testable import Mercury

@Suite("Digest Export Path Store", .serialized)
@MainActor
struct DigestExportPathStoreTests {
    @Test("Directory status is available when bookmark resolves and probe succeeds")
    func directoryStatusAvailableWhenProbeSucceeds() throws {
        let directory = try TestTemporaryDirectory(prefix: "digest-export-path-store-tests")
        defer { try? directory.cleanup() }

        let status = DigestExportPathStore.currentDirectoryStatus(
            bookmarkResolver: { _ in .resolved(url: directory.url, wasStale: false) },
            accessor: { _, work in try work() },
            probeWriter: { _, _ in }
        )

        #expect(status.isAvailable == true)
        #expect(status.issue == nil)
        #expect(status.path == directory.url.path)
        #expect(status.diagnostic.startAccessingSucceeded == true)
        #expect(status.diagnostic.writeProbeSucceeded == true)
    }

    @Test("Directory status reports missing directory when resolved folder no longer exists")
    func directoryStatusReportsMissingDirectory() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DigestExportPathStoreTests-\(UUID().uuidString)", isDirectory: true)

        let status = DigestExportPathStore.currentDirectoryStatus(
            bookmarkResolver: { _ in .resolved(url: missingURL, wasStale: false) },
            accessor: { _, work in try work() },
            probeWriter: { _, _ in }
        )

        #expect(status.isAvailable == false)
        #expect({
            if case .directoryMissing? = status.issue { return true }
            return false
        }())
        #expect(status.diagnostic.directoryExists == false)
    }

    @Test("Directory status reports expired access when security scope access is denied")
    func directoryStatusReportsExpiredAccessWhenSecurityScopeFails() throws {
        let directory = try TestTemporaryDirectory(prefix: "digest-export-path-store-tests")
        defer { try? directory.cleanup() }

        let status = DigestExportPathStore.currentDirectoryStatus(
            bookmarkResolver: { _ in .resolved(url: directory.url, wasStale: false) },
            accessor: { url, _ in
                throw SecurityScopedBookmarkAccessError.accessDenied(url.path)
            },
            probeWriter: { _, _ in }
        )

        #expect(status.isAvailable == false)
        #expect({
            if case .accessDenied? = status.issue { return true }
            return false
        }())
        #expect(status.diagnostic.startAccessingSucceeded == false)
        #expect(status.diagnostic.writeProbeSucceeded == nil)
    }

    @Test("Permission denied probe maps to expired access state")
    func permissionDeniedProbeMapsToExpiredAccessState() throws {
        let directory = try TestTemporaryDirectory(prefix: "digest-export-path-store-tests")
        defer { try? directory.cleanup() }

        let status = DigestExportPathStore.currentDirectoryStatus(
            bookmarkResolver: { _ in .resolved(url: directory.url, wasStale: false) },
            accessor: { _, work in try work() },
            probeWriter: { _, _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
        )

        #expect(status.isAvailable == false)
        #expect({
            if case .accessDenied? = status.issue { return true }
            return false
        }())
        #expect(status.diagnostic.startAccessingSucceeded == true)
        #expect(status.diagnostic.writeProbeSucceeded == false)
    }

    @Test("Non-permission probe failure maps to access check failed state")
    func genericProbeFailureMapsToAccessCheckFailedState() throws {
        let directory = try TestTemporaryDirectory(prefix: "digest-export-path-store-tests")
        defer { try? directory.cleanup() }

        let status = DigestExportPathStore.currentDirectoryStatus(
            bookmarkResolver: { _ in .resolved(url: directory.url, wasStale: false) },
            accessor: { _, work in try work() },
            probeWriter: { _, _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            }
        )

        #expect(status.isAvailable == false)
        #expect({
            if case DigestExportDirectoryIssue.writeProbeFailed? = status.issue { return true }
            return false
        }())
        #expect(status.diagnostic.startAccessingSucceeded == true)
        #expect(status.diagnostic.writeProbeSucceeded == false)
    }
}
