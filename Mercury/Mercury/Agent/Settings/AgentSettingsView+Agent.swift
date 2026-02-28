import SwiftUI

extension SummaryDetailLevel {
    var labelKey: LocalizedStringKey {
        switch self {
        case .short:    "Short"
        case .medium:   "Medium"
        case .detailed: "Detailed"
        }
    }
}

extension AgentSettingsView {
    @ViewBuilder
    var agentRightPane: some View {
        HStack(spacing: 8) {
            Text("Agent Config", bundle: bundle)
                .font(.headline)

            Spacer(minLength: 0)

            toolbarIconButton(symbol: "chart.bar.xaxis", help: String(localized: "Usage Statistics", bundle: bundle), isDisabled: selectedAgentTask == .tagging) {
                agentUsageReportContext = AgentUsageReportContext(taskType: selectedAgentTask)
            }
        }

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
                    ForEach(AgentLanguageOption.supported) { option in
                        Text(option.nativeName).tag(option.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220, alignment: .leading)
            }

            settingsRow("Detail Level") {
                Picker("", selection: $summaryDefaultDetailLevel) {
                    ForEach(SummaryDetailLevel.allCases, id: \.self) { level in
                        Text(level.labelKey, bundle: bundle).tag(level)
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

            settingsRow("Prompts") {
                customPromptsButton { try appModel.revealSummaryCustomPromptInFinder() }
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

            settingsRow("Target Language") {
                Picker("", selection: $translationDefaultTargetLanguage) {
                    ForEach(AgentLanguageOption.supported) { option in
                        Text(option.nativeName).tag(option.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 4) {
                settingsRow("Concurrency") {
                    HStack(spacing: 10) {
                        Slider(
                            value: translationConcurrencySliderBinding,
                            in: Double(TranslationSettingsKey.concurrencyRange.lowerBound)...Double(TranslationSettingsKey.concurrencyRange.upperBound)
                        )
                        Text("\(translationConcurrencyDegree)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 24, alignment: .trailing)
                    }
                    .frame(maxWidth: 260, alignment: .leading)
                }

                HStack(alignment: .top, spacing: 12) {
                    Spacer()
                        .frame(width: 220)
                    Text(
                        "Number of paragraphs translated in parallel. Lower values reduce rate-limit pressure.",
                        bundle: bundle
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            settingsRow("Prompts") {
                customPromptsButton { try appModel.revealTranslationCustomPromptInFinder() }
            }
        }
    }

    private var translationConcurrencySliderBinding: Binding<Double> {
        Binding(
            get: { Double(translationConcurrencyDegree) },
            set: { newValue in
                let rounded = Int(newValue.rounded())
                translationConcurrencyDegree = min(
                    max(rounded, TranslationSettingsKey.concurrencyRange.lowerBound),
                    TranslationSettingsKey.concurrencyRange.upperBound
                )
            }
        )
    }

    @ViewBuilder
    func customPromptsButton(reveal: @escaping @MainActor () throws -> URL) -> some View {
        Button(action: {
            Task { @MainActor in
                do {
                    let url = try reveal()
                    statusText = String(localized: "Opened", bundle: bundle)
                    outputPreview = "Revealed: \(url.path)"
                } catch {
                    applyFailureState(error)
                }
            }
        }) {
            Text("custom prompts", bundle: bundle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .underline()
    }

    @ViewBuilder
    func modelPicker(selection: Binding<Int64?>, allowNone: Bool = false) -> some View {
        let modelItems = sortedModels.compactMap { model -> (id: Int64, name: String)? in
            guard let modelId = model.id else { return nil }
            return (id: modelId, name: model.name)
        }

        if modelItems.isEmpty {
            Text("No models available", bundle: bundle)
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
