import SwiftUI

struct ReaderNotePanelView: View {
    @Environment(\.localizationBundle) private var bundle

    @Binding var text: String
    let statusText: String?
    var showsFloatingChrome: Bool = true

    var body: some View {
        EntryNoteEditorView(
            text: $text,
            statusText: statusText,
            placeholder: String(localized: "Write note about this entry...", bundle: bundle)
        )
        .padding(12)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .readerToolbarPanelSurface(showsFloatingChrome: showsFloatingChrome)
    }
}
