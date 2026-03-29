import SwiftUI

struct EntryNoteEditorView: View {
    @Environment(\.localizationBundle) private var bundle
    @State private var isEditorFocused = false
    @State private var editorHeight: CGFloat = DigestPolicy.editorMinHeight

    @Binding var text: String
    let statusText: String?
    let placeholder: String
    let autoFocus: Bool

    init(
        text: Binding<String>,
        statusText: String?,
        placeholder: String,
        autoFocus: Bool = true
    ) {
        self._text = text
        self.statusText = statusText
        self.placeholder = placeholder
        self.autoFocus = autoFocus
    }

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
                placeholder: placeholder,
                isFocused: $isEditorFocused,
                height: $editorHeight,
                minHeight: DigestPolicy.editorMinHeight,
                maxHeight: DigestPolicy.editorMaxHeight,
                growthThresholdHeight: DigestPolicy.editorGrowthThresholdHeight
            )
            .frame(height: editorHeight)
        }
        .onAppear {
            guard autoFocus else { return }
            DispatchQueue.main.async {
                isEditorFocused = true
            }
        }
    }
}
