import SwiftUI

extension AIAssistantSettingsView {
    @ViewBuilder
    var agentRightPane: some View {
        Text("Agent Config")
            .font(.headline)

        switch selectedAgentTask {
        case .summary:
            summaryAgentConfigView
        case .translation:
            translationAgentConfigView
        case .tagging:
            EmptyView()
        }
    }

    @ViewBuilder
    var summaryAgentConfigView: some View {
        propertiesCard {
            settingsRow("Primary Model") {
                modelPicker(selection: $summaryPrimaryModelId)
            }

            settingsRow("Fallback Model") {
                modelPicker(selection: $summaryFallbackModelId, allowNone: true)
            }

            settingsRow("Target Language") {
                TextField("BCP-47 (e.g. en, zh-CN)", text: $summaryDefaultTargetLanguage)
                    .textFieldStyle(.roundedBorder)
            }

            settingsRow("Detail Level") {
                Picker("", selection: $summaryDefaultDetailLevel) {
                    ForEach(AISummaryDetailLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 320, alignment: .leading)
            }

            settingsRow("Prompt Override") {
                TextField("Optional", text: $summarySystemPromptOverride, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
            }
        }

    }

    @ViewBuilder
    var translationAgentConfigView: some View {
        propertiesCard {
            settingsRow("Primary Model") {
                modelPicker(selection: $translationPrimaryModelId)
            }

            settingsRow("Fallback Model") {
                modelPicker(selection: $translationFallbackModelId, allowNone: true)
            }

            settingsRow("Status") {
                Text("Translation execution and validation panel will be added in the next step.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    func modelPicker(selection: Binding<Int64?>, allowNone: Bool = false) -> some View {
        Picker("", selection: selection) {
            if allowNone {
                Text("None").tag(Optional<Int64>.none)
            }
            ForEach(sortedModels) { model in
                if let modelId = model.id {
                    Text(model.name).tag(Optional(modelId))
                }
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
