import AppKit
import SwiftUI

struct VSplitDivider: View {
    @Binding var dimension: CGFloat
    let minDimension: CGFloat
    let maxDimension: CGFloat
    let cursor: NSCursor
    let onDragEnded: (CGFloat) -> Void

    @State private var dimensionStart: CGFloat?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(height: 10)
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
        }
        .frame(height: 10)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if dimensionStart == nil {
                    dimensionStart = dimension
                }
                let delta = value.location.y - value.startLocation.y
                let next = (dimensionStart ?? dimension) - delta
                dimension = min(max(next, minDimension), maxDimension)
            }
            .onEnded { _ in
                let clamped = min(max(dimension, minDimension), maxDimension)
                dimension = clamped
                dimensionStart = nil
                onDragEnded(clamped)
            }
    }
}
