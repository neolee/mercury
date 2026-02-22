//
//  AppModel+AgentAvailability.swift
//  Mercury
//

import Foundation
import GRDB

extension AppModel {
    // MARK: - Refresh

    /// Re-evaluates availability for all agent kinds and updates the
    /// @Published flags. Call after any settings mutation that may change
    /// whether an agent has a usable model+provider chain.
    func refreshAgentAvailability() async {
        let summary = await checkAgentAvailability(for: .summary)
        let translation = await checkAgentAvailability(for: .translation)
        isSummaryAgentAvailable = summary
        isTranslationAgentAvailable = translation
    }

    // MARK: - Per-kind check

    /// An agent kind is available when its configured route (primaryModelId →
    /// fallbackModelId → default model → newest model) resolves to at least
    /// one enabled model whose provider is also enabled. This mirrors the
    /// candidate-selection logic in `resolveAgentRouteCandidates` exactly so
    /// the availability flag and the runtime always agree. Credential reads
    /// are skipped — reachability is validated at runtime via the failure/banner UX.
    private func checkAgentAvailability(for taskType: AgentTaskType) async -> Bool {
        // Load the UserDefaults-configured model IDs — same source as resolveAgentRouteCandidates.
        let primaryModelId: Int64?
        let fallbackModelId: Int64?
        switch taskType {
        case .summary:
            let d = loadSummaryAgentDefaults()
            primaryModelId = d.primaryModelId
            fallbackModelId = d.fallbackModelId
        case .translation:
            let d = loadTranslationAgentDefaults()
            primaryModelId = d.primaryModelId
            fallbackModelId = d.fallbackModelId
        case .tagging:
            return false
        }

        do {
            return try await database.read { db in
                // Fetch all enabled models that support this task kind — same query as resolveAgentRouteCandidates.
                let models: [AgentModelProfile]
                switch taskType {
                case .summary:
                    models = try AgentModelProfile
                        .filter(Column("supportsSummary") == true)
                        .filter(Column("isEnabled") == true)
                        .fetchAll(db)
                case .translation:
                    models = try AgentModelProfile
                        .filter(Column("supportsTranslation") == true)
                        .filter(Column("isEnabled") == true)
                        .fetchAll(db)
                case .tagging:
                    return false
                }

                guard models.isEmpty == false else { return false }

                // Fetch all enabled providers — same query as resolveAgentRouteCandidates.
                let providers = try AgentProviderProfile
                    .filter(Column("isEnabled") == true)
                    .fetchAll(db)

                let modelsByID = Dictionary(uniqueKeysWithValues: models.compactMap { m in
                    m.id.map { ($0, m) }
                })
                let enabledProviderIDs = Set(providers.compactMap(\.id))

                // Build the candidate model ID list — same priority order as resolveAgentRouteCandidates.
                var routeModelIDs: [Int64] = []
                if let primaryModelId {
                    routeModelIDs.append(primaryModelId)
                } else if let def = models.first(where: { $0.isDefault }), let defId = def.id {
                    routeModelIDs.append(defId)
                } else if let newest = models.sorted(by: { $0.updatedAt > $1.updatedAt }).first, let id = newest.id {
                    routeModelIDs.append(id)
                }

                if let fallbackModelId, routeModelIDs.contains(fallbackModelId) == false {
                    routeModelIDs.append(fallbackModelId)
                }

                // Check whether any configured candidate resolves to an enabled model+provider pair.
                let hasConfiguredRoute = routeModelIDs.contains { modelID in
                    guard let model = modelsByID[modelID] else { return false }
                    return enabledProviderIDs.contains(model.providerProfileId)
                }
                if hasConfiguredRoute { return true }

                // Last-resort fallback: any enabled model with an enabled provider — mirrors resolveAgentRouteCandidates.
                let fallbackModel = models
                    .sorted { lhs, rhs in
                        if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                        return lhs.updatedAt > rhs.updatedAt
                    }
                    .first
                if let fallbackModel, enabledProviderIDs.contains(fallbackModel.providerProfileId) {
                    return true
                }

                return false
            }
        } catch {
            return false
        }
    }

    // MARK: - lastTestedAt persistence

    func persistAgentModelLastTestedAt(_ modelProfileId: Int64) async {
        do {
            try await database.write { db in
                guard var model = try AgentModelProfile
                    .filter(Column("id") == modelProfileId)
                    .fetchOne(db) else { return }
                model.lastTestedAt = Date()
                model.updatedAt = Date()
                try model.save(db)
            }
        } catch {
            // Non-critical; ignore silently.
        }
    }
}
