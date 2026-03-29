import SwiftUI

struct ReaderNotePanelView: View {
    @Environment(\.localizationBundle) private var bundle
    @State private var isEditorFocused = false
    @State private var editorHeight: CGFloat = 140

    @Binding var text: String
    let statusText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Note", bundle: bundle)
                    .font(.headline)
                Spacer()
                if let statusText, statusText.isEmpty == false {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextEditorEx(
                text: $text,
                placeholder: String(localized: "Write note about this entry...", bundle: bundle),
                isFocused: $isEditorFocused,
                height: $editorHeight,
                minHeight: ReaderNotePolicy.editorMinHeight,
                maxHeight: ReaderNotePolicy.editorMaxHeight,
                growthThresholdHeight: ReaderNotePolicy.editorGrowthThresholdHeight
            )
            .frame(height: editorHeight)
        }
        .padding(12)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        .onTapGesture {}
        .onAppear {
            DispatchQueue.main.async {
                isEditorFocused = true
            }
        }
    }
}
