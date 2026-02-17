import SwiftUI

extension AIAssistantSettingsView {
    @ViewBuilder
    var agentRightPane: some View {
        Text("Properties")
            .font(.headline)

        propertiesCard {
            settingsRow("Status") {
                Text("Agent/Task routing will be implemented in the next step.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        HStack(spacing: 10) {
            Button("Save") {}
                .disabled(true)

            Button("Reset") {}
                .disabled(true)

            Button("Test") {}
                .disabled(true)

            Text("Agent/Task not implemented yet")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
