import SwiftUI

struct AppSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            ReaderSettingsView()
                .tabItem {
                    Label("Reader", systemImage: "text.book.closed")
                }

            AIAssistantSettingsView()
                .tabItem {
                    Label("AI Assistant", systemImage: "sparkles")
                }
        }
        .frame(minWidth: 920, minHeight: 620)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var syncFeedConcurrency: Int = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Sync") {
                    SettingsSliderRow(
                        title: "Feed Sync Concurrency",
                        valueText: "\(syncFeedConcurrency)",
                        value: syncFeedConcurrencySliderBinding,
                        range: 2...10,
                        valueMinWidth: 36
                    )

                    Text("Controls parallel feed update workers during full sync. Higher values can improve speed but may increase network load.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .onAppear {
            syncFeedConcurrency = appModel.syncFeedConcurrency
        }
    }

    private var syncFeedConcurrencySliderBinding: Binding<Double> {
        Binding(
            get: { Double(syncFeedConcurrency) },
            set: { newValue in
                let normalized = min(max(Int(newValue.rounded()), 2), 10)
                syncFeedConcurrency = normalized
                appModel.setSyncFeedConcurrency(normalized)
            }
        )
    }
}

private struct AIAssistantSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var baseURL: String = "http://localhost:5810/v1"
    @State private var model: String = "qwen3"
    @State private var apiKey: String = "local"
    @State private var isTesting: Bool = false
    @State private var statusText: String = "Ready"
    @State private var outputPreview: String = ""
    @State private var latencyMs: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Connection") {
                    TextField("Base URL", text: $baseURL)
                        .textFieldStyle(.roundedBorder)

                    TextField("Model", text: $model)
                        .textFieldStyle(.roundedBorder)

                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 10) {
                        Button {
                            Task {
                                await runSmokeTest()
                            }
                        } label: {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Run Smoke Test")
                            }
                        }
                        .disabled(isTesting)

                        Text(statusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text("Runs a minimal chat completion with prompt: Reply with exactly: ok")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Result") {
                    if let latencyMs {
                        Text("Latency: \(latencyMs) ms")
                    }

                    if outputPreview.isEmpty {
                        Text("No output yet")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(outputPreview)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    @MainActor
    private func runSmokeTest() async {
        isTesting = true
        statusText = "Testing..."
        outputPreview = ""
        latencyMs = nil

        do {
            let result = try await appModel.testAIProviderConnection(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                isStreaming: false
            )
            statusText = "Success"
            outputPreview = result.outputPreview.isEmpty ? "(empty response)" : result.outputPreview
            latencyMs = result.latencyMs
        } catch {
            statusText = "Failed"
            outputPreview = error.localizedDescription
        }

        isTesting = false
    }
}
