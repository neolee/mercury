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
        await refreshAgentConfigurationSnapshotSafely()
    }

    func makeAgentAvailabilitySnapshot(
        providers: [AgentProviderProfile],
        models: [AgentModelProfile],
        summaryDefaults: SummaryAgentDefaults,
        translationDefaults: TranslationAgentDefaults,
        taggingDefaults: TaggingAgentDefaults
    ) -> AgentAvailabilitySnapshot {
        let modelsByID = Dictionary(uniqueKeysWithValues: models.compactMap { model in
            model.id.map { ($0, model) }
        })
        let providersByID = Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
            provider.id.map { ($0, provider) }
        })

        return AgentAvailabilitySnapshot(
            summary: isAgentAvailable(
                taskType: .summary,
                primaryModelId: summaryDefaults.primaryModelId,
                hasRequiredTaskSettings: summaryDefaults.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                modelsByID: modelsByID,
                providersByID: providersByID
            ),
            translation: isAgentAvailable(
                taskType: .translation,
                primaryModelId: translationDefaults.primaryModelId,
                hasRequiredTaskSettings: translationDefaults.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    && TranslationSettingsKey.concurrencyRange.contains(translationDefaults.concurrencyDegree),
                modelsByID: modelsByID,
                providersByID: providersByID
            ),
            tagging: isAgentAvailable(
                taskType: .tagging,
                primaryModelId: taggingDefaults.primaryModelId,
                hasRequiredTaskSettings: true,
                modelsByID: modelsByID,
                providersByID: providersByID
            )
        )
    }

    private func isAgentAvailable(
        taskType: AgentTaskType,
        primaryModelId: Int64?,
        hasRequiredTaskSettings: Bool,
        modelsByID: [Int64: AgentModelProfile],
        providersByID: [Int64: AgentProviderProfile]
    ) -> Bool {
        guard hasRequiredTaskSettings else { return false }
        guard let primaryModelId,
              let primaryModel = modelsByID[primaryModelId],
              primaryModel.isEnabled,
              model(primaryModel, supports: taskType),
              let primaryProvider = providersByID[primaryModel.providerProfileId],
              primaryProvider.isEnabled else {
            return false
        }

        return true
    }

    private func model(_ model: AgentModelProfile, supports taskType: AgentTaskType) -> Bool {
        switch taskType {
        case .summary:
            return model.supportsSummary
        case .translation:
            return model.supportsTranslation
        case .tagging:
            return model.supportsTagging
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
