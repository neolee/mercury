import SwiftUI

extension ContentView {
    @ViewBuilder
    var statusView: some View {
        switch appModel.bootstrapState {
        case .importing:
            Label { Text("Syncing\u{2026}", bundle: bundle) } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .failed(let message):
            Text(String(format: String(localized: "Bootstrap failed: %@", bundle: bundle), message))
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .idle, .ready:
            statusForSyncState
        }
    }

    @ViewBuilder
    var statusForSyncState: some View {
        switch appModel.syncState {
        case .syncing:
            Label { Text("Syncing\u{2026}", bundle: bundle) } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .failed(let message):
            Text(String(format: String(localized: "Sync failed: %@", bundle: bundle), message))
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .idle:
            if let userErrorLine = userErrorStatusLine {
                Text(userErrorLine)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let activeTask = activeTaskLine {
                Text(activeTask)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                TimelineView(.everyMinute) { timeline in
                    Text(String(
                        format: String(localized: "Feeds: %lld \u{00B7} Entries: %lld \u{00B7} Unread: %lld \u{00B7} Last sync: %@", bundle: bundle),
                        Int64(appModel.feedCount),
                        Int64(appModel.entryCount),
                        Int64(appModel.totalUnreadCount),
                        lastSyncDescription(relativeTo: timeline.date)
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }
        }
    }

    var userErrorStatusLine: String? {
        guard let error = appModel.taskCenter.latestUserError else { return nil }
        return "\(error.title): \(error.message)"
    }

    func lastSyncDescription(relativeTo now: Date) -> String {
        guard let lastSyncAt = appModel.lastSyncAt else {
            return String(localized: "never", bundle: bundle)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        if let override = LanguageManager.shared.languageOverride {
            formatter.locale = Locale(identifier: override)
        }
        return formatter.localizedString(for: lastSyncAt, relativeTo: now)
    }

    var activeTaskLine: String? {
        guard let task = appModel.taskCenter.tasks.first(where: { $0.state.isTerminal == false }) else {
            return nil
        }

        let progressText: String
        if let progress = task.progress {
            progressText = "\(Int((progress * 100).rounded()))%"
        } else {
            progressText = "--"
        }
        let message = task.message ?? "Running"
        return "\(task.title) · \(progressText) · \(message)"
    }
}
