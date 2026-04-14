//
//  FeedParserRepairUseCase.swift
//  Mercury
//

import Foundation
import FeedKit
import GRDB

struct FeedParserRepairSample: Sendable, Equatable {
    let entryId: Int64
    let guid: String
    let oldURL: String
    let newURL: String
}

struct FeedParserRepairSkippedSample: Sendable, Equatable {
    let entryId: Int64
    let guid: String
    let oldURL: String
    let newURL: String
    let reason: String
}

struct FeedParserRepairEventPayload: Sendable, Equatable {
    let feedId: Int64
    let feedTitle: String?
    let feedURL: String
    let parserVersion: Int
    let repairCount: Int
    let skippedCount: Int
    let samples: [FeedParserRepairSample]
    let skippedSamples: [FeedParserRepairSkippedSample]
    let contentRowsDeleted: Int
    let cacheRowsDeleted: Int
    let stage: String?
    let errorDescription: String?
}

enum FeedParserRepairEvent: Sendable, Equatable {
    case started(FeedParserRepairEventPayload)
    case completed(FeedParserRepairEventPayload)
    case skipped(FeedParserRepairEventPayload)
    case failed(FeedParserRepairEventPayload)
}

struct FeedParserRepairUseCase: Sendable {
    private struct DiffCandidate {
        let guid: String
        let oldURL: String
        let newURL: String
    }

    private struct RepairPlanEntry {
        let entryId: Int64
        let guid: String
        let oldURL: String
        let newURL: String
    }

    private struct RepairPlan {
        let candidateCount: Int
        let repairs: [RepairPlanEntry]
        let skippedCount: Int
        let skippedSamples: [FeedParserRepairSkippedSample]
    }

    private struct RepairExecutionResult {
        let repairedSamples: [FeedParserRepairSample]
        let repairedCount: Int
        let skippedSamples: [FeedParserRepairSkippedSample]
        let skippedCount: Int
        let contentRowsDeleted: Int
        let cacheRowsDeleted: Int
    }

    let database: DatabaseManager

    func verifyAndRepairIfNeeded(
        feed: Feed,
        parsedFeed: FeedKit.Feed,
        onEvent: (@Sendable (_ event: FeedParserRepairEvent) async -> Void)? = nil
    ) async throws {
        guard let feedId = feed.id else { return }
        guard (feed.feedParserVersion ?? 0) < FeedParserVersion.current else { return }

        guard case .atom(let atom) = parsedFeed, let atomEntries = atom.entries, atomEntries.isEmpty == false else {
            try await markFeedParserVersionCurrent(feedId: feedId)
            return
        }

        let baseURLString = feed.siteURL ?? feed.feedURL
        let diffCandidates = atomEntries.compactMap { diffCandidate(from: $0, baseURLString: baseURLString) }

        guard diffCandidates.isEmpty == false else {
            try await markFeedParserVersionCurrent(feedId: feedId)
            return
        }

        let plan = try await loadRepairPlan(feedId: feedId, diffCandidates: diffCandidates)
        guard plan.candidateCount > 0 else {
            try await markFeedParserVersionCurrent(feedId: feedId)
            return
        }

        let startedPayload = makePayload(
            feed: feed,
            repairCount: plan.candidateCount,
            skippedCount: plan.skippedCount,
            repairedSamples: Array(plan.repairs.prefix(5)).map {
                FeedParserRepairSample(
                    entryId: $0.entryId,
                    guid: $0.guid,
                    oldURL: $0.oldURL,
                    newURL: $0.newURL
                )
            },
            skippedSamples: plan.skippedSamples,
            contentRowsDeleted: 0,
            cacheRowsDeleted: 0,
            stage: "prepare",
            errorDescription: nil
        )

        if let onEvent {
            await onEvent(.started(startedPayload))
        }

        do {
            let execution = try await database.write { db in
                try applyRepairPlan(feedId: feedId, plan: plan, db: db)
            }

            if execution.skippedSamples.isEmpty == false, let onEvent {
                await onEvent(.skipped(makePayload(
                    feed: feed,
                    repairCount: execution.repairedCount,
                    skippedCount: execution.skippedCount,
                    repairedSamples: execution.repairedSamples,
                    skippedSamples: execution.skippedSamples,
                    contentRowsDeleted: execution.contentRowsDeleted,
                    cacheRowsDeleted: execution.cacheRowsDeleted,
                    stage: "apply",
                    errorDescription: nil
                )))
            }

            if let onEvent {
                await onEvent(.completed(makePayload(
                    feed: feed,
                    repairCount: execution.repairedCount,
                    skippedCount: execution.skippedCount,
                    repairedSamples: execution.repairedSamples,
                    skippedSamples: execution.skippedSamples,
                    contentRowsDeleted: execution.contentRowsDeleted,
                    cacheRowsDeleted: execution.cacheRowsDeleted,
                    stage: "apply",
                    errorDescription: nil
                )))
            }
        } catch {
            if let onEvent {
                await onEvent(.failed(makePayload(
                    feed: feed,
                    repairCount: plan.candidateCount,
                    skippedCount: plan.skippedCount,
                    repairedSamples: Array(plan.repairs.prefix(5)).map {
                        FeedParserRepairSample(
                            entryId: $0.entryId,
                            guid: $0.guid,
                            oldURL: $0.oldURL,
                            newURL: $0.newURL
                        )
                    },
                    skippedSamples: plan.skippedSamples,
                    contentRowsDeleted: 0,
                    cacheRowsDeleted: 0,
                    stage: "apply",
                    errorDescription: error.localizedDescription
                )))
            }
            throw error
        }
    }

    private func diffCandidate(from entry: AtomFeedEntry, baseURLString: String?) -> DiffCandidate? {
        guard let guid = entry.id else { return nil }
        let selection = FeedEntryURLResolver.atomURLSelection(
            links: entry.links,
            baseURLString: baseURLString
        )
        guard let oldURL = selection.legacyURL, let newURL = selection.preferredURL, oldURL != newURL else {
            return nil
        }
        return DiffCandidate(guid: guid, oldURL: oldURL, newURL: newURL)
    }

    private func loadRepairPlan(feedId: Int64, diffCandidates: [DiffCandidate]) async throws -> RepairPlan {
        try await database.read { db in
            let guids = Array(Set(diffCandidates.map(\.guid)))
            let newURLs = Array(Set(diffCandidates.map(\.newURL)))

            let existingEntries = try Entry
                .filter(Column("feedId") == feedId)
                .filter(guids.contains(Column("guid")))
                .fetchAll(db)

            let conflictingEntries = try Entry
                .filter(Column("feedId") == feedId)
                .filter(newURLs.contains(Column("url")))
                .fetchAll(db)

            let entriesByGuid: [String: Entry] = Dictionary(
                uniqueKeysWithValues: existingEntries.compactMap { entry in
                    guard let guid = entry.guid else { return nil }
                    return (guid, entry)
                }
            )

            var ownersByURL: [String: Int64] = [:]
            for entry in conflictingEntries {
                guard let entryId = entry.id, let url = entry.url else { continue }
                ownersByURL[url] = entryId
            }

            var repairs: [RepairPlanEntry] = []
            var skipped: [FeedParserRepairSkippedSample] = []
            repairs.reserveCapacity(diffCandidates.count)

            for candidate in diffCandidates {
                guard let existing = entriesByGuid[candidate.guid], let entryId = existing.id else {
                    continue
                }
                guard existing.url != candidate.newURL else {
                    continue
                }
                guard existing.url == candidate.oldURL else {
                    continue
                }

                if let ownerEntryId = ownersByURL[candidate.newURL], ownerEntryId != entryId {
                    skipped.append(FeedParserRepairSkippedSample(
                        entryId: entryId,
                        guid: candidate.guid,
                        oldURL: candidate.oldURL,
                        newURL: candidate.newURL,
                        reason: "url-conflict-with-another-entry"
                    ))
                    continue
                }

                repairs.append(RepairPlanEntry(
                    entryId: entryId,
                    guid: candidate.guid,
                    oldURL: candidate.oldURL,
                    newURL: candidate.newURL
                ))
            }

            return RepairPlan(
                candidateCount: repairs.count + skipped.count,
                repairs: repairs,
                skippedCount: skipped.count,
                skippedSamples: Array(skipped.prefix(5))
            )
        }
    }

    private func applyRepairPlan(feedId: Int64, plan: RepairPlan, db: Database) throws -> RepairExecutionResult {
        var repairedSamples: [FeedParserRepairSample] = []
        repairedSamples.reserveCapacity(plan.repairs.count)

        for repair in plan.repairs {
            _ = try Entry
                .filter(Column("id") == repair.entryId)
                .updateAll(db, Column("url").set(to: repair.newURL))

            repairedSamples.append(FeedParserRepairSample(
                entryId: repair.entryId,
                guid: repair.guid,
                oldURL: repair.oldURL,
                newURL: repair.newURL
            ))
        }

        let repairedEntryIds = plan.repairs.map(\.entryId)
        let contentRowsDeleted: Int
        let cacheRowsDeleted: Int
        if repairedEntryIds.isEmpty {
            contentRowsDeleted = 0
            cacheRowsDeleted = 0
        } else {
            contentRowsDeleted = try Content
                .filter(repairedEntryIds.contains(Column("entryId")))
                .deleteAll(db)
            cacheRowsDeleted = try ContentHTMLCache
                .filter(repairedEntryIds.contains(Column("entryId")))
                .deleteAll(db)
        }

        try Feed
            .filter(Column("id") == feedId)
            .updateAll(db, Column("feedParserVersion").set(to: FeedParserVersion.current))

        return RepairExecutionResult(
            repairedSamples: Array(repairedSamples.prefix(5)),
            repairedCount: repairedSamples.count,
            skippedSamples: plan.skippedSamples,
            skippedCount: plan.skippedCount,
            contentRowsDeleted: contentRowsDeleted,
            cacheRowsDeleted: cacheRowsDeleted
        )
    }

    private func markFeedParserVersionCurrent(feedId: Int64) async throws {
        _ = try await database.write { db in
            try Feed
                .filter(Column("id") == feedId)
                .updateAll(db, Column("feedParserVersion").set(to: FeedParserVersion.current))
        }
    }

    private func makePayload(
        feed: Feed,
        repairCount: Int,
        skippedCount: Int,
        repairedSamples: [FeedParserRepairSample],
        skippedSamples: [FeedParserRepairSkippedSample],
        contentRowsDeleted: Int,
        cacheRowsDeleted: Int,
        stage: String?,
        errorDescription: String?
    ) -> FeedParserRepairEventPayload {
        FeedParserRepairEventPayload(
            feedId: feed.id ?? 0,
            feedTitle: feed.title,
            feedURL: feed.feedURL,
            parserVersion: FeedParserVersion.current,
            repairCount: repairCount,
            skippedCount: skippedCount,
            samples: Array(repairedSamples.prefix(5)),
            skippedSamples: Array(skippedSamples.prefix(5)),
            contentRowsDeleted: contentRowsDeleted,
            cacheRowsDeleted: cacheRowsDeleted,
            stage: stage,
            errorDescription: errorDescription
        )
    }
}
