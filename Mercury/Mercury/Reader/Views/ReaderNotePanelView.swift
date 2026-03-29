import SwiftUI

struct ReaderNotePanelView: View {
    @Environment(\.localizationBundle) private var bundle

    @Binding var text: String
    let statusText: String?

    var body: some View {
        EntryNoteEditorView(
            text: $text,
            statusText: statusText,
            placeholder: String(localized: "Write note about this entry...", bundle: bundle)
        )
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
    }
}
