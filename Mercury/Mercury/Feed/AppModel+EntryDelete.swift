import Foundation

extension AppModel {
    @discardableResult
    func deleteEntry(entryId: Int64) async throws -> Bool {
        guard isTagBatchLifecycleActive == false else {
            throw EntryDeleteError.blockedByActiveTagBatch
        }

        await cancelEntryScopedTasks(entryId: entryId)

        let didDelete = try await entryDeleteUseCase.deleteEntry(entryId: entryId)
        guard didDelete else {
            return false
        }

        entryStore.removeLoadedEntry(entryId: entryId)
        await refreshCounts()
        return true
    }

    func cancelEntryScopedTasks(entryId: Int64) async {
        await cancelTaggingPanelRun(entryId: entryId)

        let snapshot = await agentRuntimeEngine.snapshot()
        let owners: [AgentRunOwner] = Array(snapshot.states).compactMap { element in
            let owner = element.key
            let state = element.value
            guard owner.entryId == entryId else {
                return nil
            }
            guard owner.taskKind != .taggingBatch else {
                return nil
            }
            guard state.phase.isTerminal == false else {
                return nil
            }
            return owner
        }

        for owner in owners {
            if let taskId = snapshot.states[owner]?.taskId {
                await cancelTask(taskId)
            }
            _ = await agentRuntimeEngine.finish(
                owner: owner,
                terminalPhase: .cancelled,
                reason: .cancelled
            )
        }
    }
}

private extension AgentRunPhase {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .timedOut:
            return true
        case .idle, .waiting, .requesting, .generating, .persisting:
            return false
        }
    }
}
