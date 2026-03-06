import SwiftUI

struct BatchTaggingSheetView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.localizationBundle) private var bundle

    @StateObject private var viewModel = BatchTaggingSheetViewModel()
    @State private var isDiscardConfirmPresented = false
    @State private var isStartConfirmPresented = false
    @State private var isCompletionAlertPresented = false
    @State private var lastCompletionAlertRunId: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 520)
        .task {
            await viewModel.bindIfNeeded(appModel: appModel)
        }
        .onChange(of: viewModel.scope) { _, _ in
            Task { await viewModel.refreshCandidateCount() }
        }
        .onChange(of: viewModel.skipAlreadyApplied) { _, _ in
            Task { await viewModel.refreshCandidateCount() }
        }
        .onChange(of: viewModel.skipAlreadyTagged) { _, _ in
            Task { await viewModel.refreshCandidateCount() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NSWindowDidBecomeKeyNotification"))) { _ in
            Task { await viewModel.refreshCandidateCount() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NSWindowDidBecomeMainNotification"))) { _ in
            Task { await viewModel.refreshCandidateCount() }
        }
        .onChange(of: viewModel.completedRunIDForAlert) { _, newRunId in
            guard let runId = newRunId else { return }
            guard lastCompletionAlertRunId != runId else { return }
            lastCompletionAlertRunId = runId
            isCompletionAlertPresented = true
        }
        .confirmationDialog(
            String(localized: "Abort Batch Run", bundle: bundle),
            isPresented: $isDiscardConfirmPresented,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await viewModel.discardRun() }
            } label: {
                Text("Abort", bundle: bundle)
            }
            Button(role: .cancel) {
            } label: {
                Text("Cancel", bundle: bundle)
            }
        } message: {
            Text("Aborting removes all staged batch data and cannot be undone.", bundle: bundle)
        }
        .alert(
            String(localized: "Large Batch Confirmation", bundle: bundle),
            isPresented: $isStartConfirmPresented
        ) {
            Button(String(localized: "Continue", bundle: bundle)) {
                Task { await viewModel.startRun() }
            }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        } message: {
            Text(
                "Large target size detected. Please confirm scope and settings before starting. This batch may consume a large amount of tokens and take considerable time. If a paid provider is used, costs may be significant.",
                bundle: bundle
            )
        }
        .alert(
            String(localized: "Batch Apply Completed", bundle: bundle),
            isPresented: $isCompletionAlertPresented
        ) {
            Button(String(localized: "OK", bundle: bundle)) {
                dismiss()
            }
        } message: {
            Text(completionSummaryText)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Batch Tagging", bundle: bundle)
                    .font(.title3.weight(.semibold))
                Text(statusLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.status {
        case .configure, .done, .cancelled, .failed:
            configurePane
        case .running:
            runningPane
        case .readyNext:
            readyNextPane
        case .review:
            reviewPane
        case .applying:
            applyingPane
        }
    }

    private var configurePane: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Tagging entries", bundle: bundle)
                    Picker(selection: $viewModel.scope) {
                        Text("1 week", bundle: bundle).tag(TagBatchSelectionScope.pastWeek)
                        Text("1 month", bundle: bundle).tag(TagBatchSelectionScope.pastMonth)
                        Text("3 months", bundle: bundle).tag(TagBatchSelectionScope.pastThreeMonths)
                        Text("6 months", bundle: bundle).tag(TagBatchSelectionScope.pastSixMonths)
                        Text("12 months", bundle: bundle).tag(TagBatchSelectionScope.pastTwelveMonths)
                        Text("All unread", bundle: bundle).tag(TagBatchSelectionScope.unreadEntries)
                        Text("All", bundle: bundle).tag(TagBatchSelectionScope.allEntries)
                    } label: {
                        Text("Tagging entries", bundle: bundle)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }

                Toggle(isOn: $viewModel.skipAlreadyApplied) {
                    Text("Skip entries that were already applied by batch", bundle: bundle)
                }

                Toggle(isOn: $viewModel.skipAlreadyTagged) {
                    Text("Skip entries that have already been tagged", bundle: bundle)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Model request concurrency", bundle: bundle)
                    Text("\(viewModel.concurrency)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 24, alignment: .trailing)
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.concurrency) },
                            set: { viewModel.concurrency = Int($0.rounded()) }
                        ),
                        in: 1...5
                    )
                    .frame(width: 160)
                }

                Text(
                    "Controls simultaneous model requests in one batch run. Higher values may improve speed but can hit provider concurrency limits. If rate-limit issues occur, set this to 1.",
                    bundle: bundle
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Estimated batch entries", bundle: bundle)
                    Text("\(viewModel.totalCandidateCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if viewModel.exceedsWarningThreshold {
                    Text(
                        "Large target size detected. This batch may consume many tokens and take longer to finish. Paid providers may incur significant cost. Start will ask for confirmation.",
                        bundle: bundle
                    )
                    .font(.footnote)
                    .foregroundStyle(ViewSemanticStyle.warningColor)
                }

                if viewModel.exceedsHardSafetyCap {
                    Text(
                        "Estimated batch entries exceed hard safety limit (\(BatchTaggingPolicy.absoluteSafetyCap)). To control run risk, please narrow the selection scope.",
                        bundle: bundle
                    )
                    .font(.footnote)
                    .foregroundStyle(ViewSemanticStyle.errorColor)
                }

                if let error = viewModel.error {
                    Text(errorText(error))
                        .font(.footnote)
                        .foregroundStyle(ViewSemanticStyle.errorColor)
                }

                if let notice = viewModel.notice, viewModel.exceedsHardSafetyCap == false {
                    Text(noticeText(notice))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    private var runningPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(
                value: progressValue,
                total: 1
            )
            .progressViewStyle(.linear)

            Text("Processed \(viewModel.processedCount) / \(max(viewModel.totalCandidateCount, 1))", bundle: bundle)
                .font(.subheadline)

            HStack(spacing: 12) {
                Text("Succeeded: \(viewModel.succeededCount)", bundle: bundle)
                Text("Failed: \(viewModel.failedCount)", bundle: bundle)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if let notice = viewModel.notice {
                Text(noticeText(notice))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var readyNextPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run completed. Review the result summary and choose the next step.", bundle: bundle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Processed \(viewModel.processedCount) / \(max(viewModel.totalCandidateCount, 1))", bundle: bundle)
                .font(.subheadline)

            HStack(spacing: 12) {
                Text("Succeeded: \(viewModel.succeededCount)", bundle: bundle)
                Text("Failed: \(viewModel.failedCount)", bundle: bundle)
                Text("Suggested tags: \(viewModel.totalSuggestedTags)", bundle: bundle)
                Text("New tags: \(viewModel.newTagCount)", bundle: bundle)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if viewModel.hasReviewRequired {
                Text("New tags require review before apply.", bundle: bundle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("No new tags to review. You can apply directly, or abort the run.", bundle: bundle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var reviewPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review new tag proposals before apply.", bundle: bundle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            List(viewModel.reviewRows, id: \.normalizedName) { row in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.displayName)
                        Text("hits: \(row.hitCount), entries: \(row.sampleEntryCount)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { row.decision },
                        set: { decision in
                            Task {
                                await viewModel.setDecision(
                                    normalizedName: row.normalizedName,
                                    decision: decision
                                )
                            }
                        }
                    )) {
                        Text("Pending", bundle: bundle).tag(TagBatchReviewDecision.pending)
                        Text("Keep", bundle: bundle).tag(TagBatchReviewDecision.keep)
                        Text("Discard", bundle: bundle).tag(TagBatchReviewDecision.discard)
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                .padding(.vertical, 2)
            }

            if let error = viewModel.error {
                Text(errorText(error))
                    .font(.footnote)
                    .foregroundStyle(ViewSemanticStyle.errorColor)
            }
        }
    }

    private var applyingPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Applying reviewed decisions to tag assignments...", bundle: bundle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Processed \(viewModel.processedCount) / \(max(viewModel.totalCandidateCount, 1))", bundle: bundle)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if viewModel.isLifecycleLocked {
                Button(role: .destructive) {
                    isDiscardConfirmPresented = true
                } label: {
                    Text("Abort", bundle: bundle)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.isBusy || viewModel.status == .running)
            } else {
                Button {
                    dismiss()
                } label: {
                    Text("Close", bundle: bundle)
                }
            }

            Spacer()

            if viewModel.status == .review {
                if viewModel.reviewRows.isEmpty == false {
                    Button {
                        Task { await viewModel.setAllReviewDecisions(decision: .keep) }
                    } label: {
                        Text("Keep All", bundle: bundle)
                    }

                    Button {
                        Task { await viewModel.setAllReviewDecisions(decision: .discard) }
                    } label: {
                        Text("Discard All", bundle: bundle)
                    }
                }

                Button {
                    Task { await viewModel.applyDecisions() }
                } label: {
                    Text("Apply Decisions", bundle: bundle)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isBusy || viewModel.hasPendingReviewDecisions)
            }

            if viewModel.status == .running {
                Button {
                    Task { await viewModel.requestCancelRunning() }
                } label: {
                    if viewModel.isStopRequested {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Stopping...", bundle: bundle)
                        }
                    } else {
                        Text("Stop", bundle: bundle)
                    }
                }
                .disabled(viewModel.isBusy || viewModel.isStopRequested)
            }

            if viewModel.status == .readyNext {
                Button {
                    Task { await viewModel.continueFromReadyNext() }
                } label: {
                    Text(viewModel.hasReviewRequired ? "Review" : "Apply", bundle: bundle)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isBusy)
            }

            if viewModel.canStart {
                Button {
                    Task { await viewModel.resetConfigurationToDefaults() }
                } label: {
                    Text("Reset to Default", bundle: bundle)
                }
                .disabled(viewModel.isBusy)

                Button {
                    if viewModel.exceedsWarningThreshold {
                        isStartConfirmPresented = true
                    } else {
                        Task { await viewModel.startRun() }
                    }
                } label: {
                    Text("Start Batch", bundle: bundle)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isBusy || viewModel.isStartBlocked)
            }
        }
    }

    private var progressValue: Double {
        guard viewModel.totalCandidateCount > 0 else { return 0 }
        return min(max(Double(viewModel.processedCount) / Double(viewModel.totalCandidateCount), 0), 1)
    }

    private var statusLabel: String {
        switch viewModel.status {
        case .configure:
            return String(localized: "Configure", bundle: bundle)
        case .running:
            return String(localized: "Running", bundle: bundle)
        case .readyNext:
            return String(localized: "Ready", bundle: bundle)
        case .review:
            return String(localized: "Review", bundle: bundle)
        case .applying:
            return String(localized: "Applying", bundle: bundle)
        case .done:
            return String(localized: "Done", bundle: bundle)
        case .cancelled:
            return String(localized: "Cancelled", bundle: bundle)
        case .failed:
            return String(localized: "Failed", bundle: bundle)
        }
    }

    private var completionSummaryText: String {
        String(
            localized: "Batch apply completed. Processed \(viewModel.processedCount), succeeded \(viewModel.succeededCount), failed \(viewModel.failedCount), inserted assignments \(viewModel.insertedEntryTagCount), created tags \(viewModel.createdTagCount), kept proposals \(viewModel.keptProposalCount), discarded proposals \(viewModel.discardedProposalCount).",
            bundle: bundle
        )
    }

    private func noticeText(_ notice: BatchTaggingSheetNotice) -> String {
        switch notice {
        case .noEligibleEntries:
            return String(localized: "No eligible entries found for the selected scope.", bundle: bundle)
        case .hardSafetyCapExceeded(let limit):
            return String(
                localized: "Estimated batch entries exceed hard safety limit (\(limit)). To reduce run risk, please narrow the scope.",
                bundle: bundle
            )
        case .stopRequested:
            return String(
                localized: "Stop requested. Waiting for in-flight requests to finish before next actions are available.",
                bundle: bundle
            )
        case .stopBeforeAbort:
            return String(
                localized: "Stop the run first and wait until all in-flight requests complete before aborting.",
                bundle: bundle
            )
        case .activeRunExists:
            return String(
                localized: "Another batch run is active. Finish or discard it before starting a new run.",
                bundle: bundle
            )
        case .promptTemplateFallback:
            return AgentPromptCustomizationConfig.tagging.invalidTemplateFallbackMessage(bundle: bundle)
        }
    }

    private func errorText(_ error: BatchTaggingSheetError) -> String {
        switch error {
        case .runNotFound:
            return String(localized: "Batch run not found.", bundle: bundle)
        case .runStillRunning:
            return String(
                localized: "Batch run is still running. Stop first and wait for in-flight requests to complete before aborting.",
                bundle: bundle
            )
        case .runNotReadyForReview:
            return String(localized: "Batch run is not ready for review.", bundle: bundle)
        case .runNotReadyForApply:
            return String(localized: "Batch run is not in review/applying state.", bundle: bundle)
        case .reviewDecisionsPending:
            return String(localized: "Resolve all review decisions before apply.", bundle: bundle)
        case .missingRunID:
            return String(localized: "Batch run identifier is missing.", bundle: bundle)
        case .operationFailed(let reason):
            return AgentRuntimeProjection.failureMessage(for: reason, taskKind: .taggingBatch)
        }
    }
}
