//
//  ReaderTranslationView.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI
import AppKit
import CryptoKit

// MARK: - Supporting Types

struct TranslationQueuedRunRequest: Sendable {
    let taskId: UUID
    let owner: AgentRunOwner
    let slotKey: TranslationSlotKey
    let executionSnapshot: TranslationSourceSegmentsSnapshot
    let projectionSnapshot: TranslationSourceSegmentsSnapshot
    let targetLanguage: String
    let initialTranslatedBySegmentID: [String: String]
    let initialPendingSegmentIDs: Set<String>
    let initialFailedSegmentIDs: Set<String>
    let isRetry: Bool
}

struct TranslationProjectionState: Sendable {
    let slotKey: TranslationSlotKey
    let sourceSnapshot: TranslationSourceSegmentsSnapshot
    var translatedBySegmentID: [String: String]
    var pendingSegmentIDs: Set<String>
    var failedSegmentIDs: Set<String>
}

struct TranslationRetryMergeContext: Sendable {
    let sourceSnapshot: TranslationSourceSegmentsSnapshot
    let baseTranslatedBySegmentID: [String: String]
}

struct TranslationPersistedCoverage: Sendable {
    let translatedBySegmentID: [String: String]
    let unresolvedSegmentIDs: Set<String>

    var hasTranslatedSegments: Bool {
        translatedBySegmentID.isEmpty == false
    }
}

enum TranslationReaderAction: Sendable {
    case retrySegment(entryId: Int64, slotKey: TranslationSlotKey, segmentId: String)
    case retryFailed(entryId: Int64, slotKey: TranslationSlotKey)
}

// MARK: - ReaderTranslationView

/// Zero-height view that manages translation agent state, toolbar items, and
/// `readerHTML` / `sourceReaderHTML` mutations for the reader detail container.
///
/// Renders as `Color.clear` with `.frame(height: 0)` so it occupies no visual
/// space while still contributing toolbar items and lifecycle hooks to the view
/// hierarchy.
struct ReaderTranslationView: View {
    let entry: Entry?
    @Binding var displayedEntryId: Int64?
    @Binding var readerHTML: String?
    @Binding var sourceReaderHTML: String?
    @Binding var topBannerMessage: ReaderBannerMessage?
    let readingModeRaw: String

    @EnvironmentObject var appModel: AppModel
    @Environment(\.openSettings) var openSettings
    @Environment(\.localizationBundle) var bundle
    @Binding var translationMode: TranslationMode
    @Binding var hasPersistedTranslationForCurrentSlot: Bool
    @Binding var hasResumableTranslationCheckpointForCurrentSlot: Bool
    @Binding var translationToggleRequested: Bool
    @Binding var translationClearRequested: Bool
    @Binding var translationActionURL: URL?
    @Binding var isTranslationRunningForCurrentEntry: Bool

    @State var translationCurrentSlotKey: TranslationSlotKey?
    @State var translationManualStartRequestedEntryId: Int64?
    @State var translationRunningOwner: AgentRunOwner?
    @State var translationQueuedRunPayloads: [AgentRunOwner: TranslationQueuedRunRequest] = [:]
    @State var translationTaskIDByOwner: [AgentRunOwner: UUID] = [:]
    @State var translationProjectionStateByOwner: [AgentRunOwner: TranslationProjectionState] = [:]
    @State var translationRetryMergeContextByOwner: [AgentRunOwner: TranslationRetryMergeContext] = [:]
    @State var translationPhaseByOwner: [AgentRunOwner: AgentRunPhase] = [:]
    @State var translationNoticeByOwner: [AgentRunOwner: String] = [:]
    @State var translationProjectionDebounceTask: Task<Void, Never>?

    var body: some View {
        Color.clear
            .onChange(of: translationToggleRequested) { _, requested in
                guard requested else { return }
                translationToggleRequested = false
                toggleTranslationMode()
            }
            .onChange(of: translationClearRequested) { _, requested in
                guard requested else { return }
                translationClearRequested = false
                Task { await clearTranslationForCurrentEntry() }
            }
            .onChange(of: displayedEntryId) { previousId, newId in
                hasPersistedTranslationForCurrentSlot = false
                hasResumableTranslationCheckpointForCurrentSlot = false
                translationCurrentSlotKey = nil
                translationMode = .original
                translationManualStartRequestedEntryId = nil
                translationRunningOwner = nil
                translationNoticeByOwner.removeAll()
                translationTaskIDByOwner.removeAll()
                translationProjectionStateByOwner.removeAll()
                translationRetryMergeContextByOwner.removeAll()
                translationProjectionDebounceTask?.cancel()
                translationProjectionDebounceTask = nil
                refreshRunningStateForCurrentEntry()
                if let previousId {
                    Task {
                        await abandonTranslationWaiting(for: previousId, nextSelectedEntryId: newId)
                    }
                }
            }
            .onChange(of: readingModeRaw) { _, newValue in
                let mode = ReadingMode(rawValue: newValue) ?? .reader
                if mode != .reader {
                    translationMode = .original
                } else {
                    Task {
                        await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: true)
                    }
                }
            }
            .onChange(of: sourceReaderHTML) { _, newHTML in
                guard newHTML != nil else { return }
                Task {
                    await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: true)
                    await refreshTranslationClearAvailabilityForCurrentEntry()
                }
            }
            .onChange(of: translationActionURL) { _, actionURL in
                guard let actionURL else { return }
                translationActionURL = nil
                Task {
                    await handleTranslationActionURL(actionURL)
                }
            }
            .task {
                await observeRuntimeEventsForTranslation()
            }
            .onReceive(NotificationCenter.default.publisher(for: .translationAgentDefaultsDidChange)) { _ in
                Task {
                    await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: false)
                    await refreshTranslationClearAvailabilityForCurrentEntry()
                }
            }
    }
}
