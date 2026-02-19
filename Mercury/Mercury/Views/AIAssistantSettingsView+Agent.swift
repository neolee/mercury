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
                Picker("", selection: $summaryDefaultTargetLanguage) {
                    ForEach(SummaryLanguageOption.supported) { option in
                        Text(option.nativeName).tag(option.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220, alignment: .leading)
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

            settingsRow("Warn on auto-summary") {
                Toggle("", isOn: $summaryAutoEnableWarning)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
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
        let modelItems = sortedModels.compactMap { model -> (id: Int64, name: String)? in
            guard let modelId = model.id else { return nil }
            return (id: modelId, name: model.name)
        }

        if modelItems.isEmpty {
            Text("No models available")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if allowNone {
            Picker("", selection: selection) {
                Text("None").tag(Optional<Int64>.none)
                ForEach(modelItems, id: \.id) { model in
                    Text(model.name).tag(Optional<Int64>.some(model.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let requiredSelection = Binding<Int64>(
                get: {
                    selection.wrappedValue
                        ?? modelItems.first?.id
                        ?? 0
                },
                set: { newValue in
                    selection.wrappedValue = newValue
                }
            )
            Picker("", selection: requiredSelection) {
                ForEach(modelItems, id: \.id) { model in
                    Text(model.name).tag(model.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                if selection.wrappedValue == nil {
                    selection.wrappedValue = modelItems.first?.id
                }
            }
        }
    }
}
