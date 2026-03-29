import SwiftUI

enum ReaderToolbarPanelKind: Equatable {
    case theme
    case tags
    case note
}

struct ReaderToolbarPanelHostView<Content: View>: View {
    let activePanel: ReaderToolbarPanelKind?
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        if activePanel != nil {
            ZStack(alignment: .topTrailing) {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        onClose()
                    }

                HStack(alignment: .top, spacing: 8) {
                    content()
                }
                .padding(.top, 8)
                .padding(.trailing, 12)
            }
        }
    }
}
