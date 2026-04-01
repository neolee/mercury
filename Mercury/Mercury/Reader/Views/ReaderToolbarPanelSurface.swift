import SwiftUI

enum ReaderToolbarPanelKind: Equatable {
    case theme
    case tags
    case note
}

extension View {
    @ViewBuilder
    func readerToolbarPanelSurface(showsFloatingChrome: Bool = true) -> some View {
        if showsFloatingChrome {
            self
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
                .onTapGesture {}
        } else {
            self
        }
    }
}
