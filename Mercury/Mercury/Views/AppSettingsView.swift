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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("General")
                .font(.title3.weight(.semibold))
            Text("General settings will be added in Stage 3.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }
}

private struct AIAssistantSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI Assistant")
                .font(.title3.weight(.semibold))
            Text("AI Assistant settings will be added in Stage 3.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }
}
