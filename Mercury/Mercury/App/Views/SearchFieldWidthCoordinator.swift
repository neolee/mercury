import AppKit
import SwiftUI

struct SearchFieldWidthCoordinator: NSViewRepresentable {
    let preferredWidth: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            hostView: nsView,
            preferredWidth: preferredWidth,
            minWidth: minWidth,
            maxWidth: maxWidth
        )
    }

    final class Coordinator: NSObject {
        private static let minConstraintIdentifier = "Mercury.ToolbarSearch.minWidth"
        private static let maxConstraintIdentifier = "Mercury.ToolbarSearch.maxWidth"

        func update(
            hostView: NSView,
            preferredWidth: CGFloat,
            minWidth: CGFloat,
            maxWidth: CGFloat
        ) {
            guard let window = hostView.window else {
                DispatchQueue.main.async { [weak hostView, weak self] in
                    guard let hostView, let self else { return }
                    self.update(
                        hostView: hostView,
                        preferredWidth: preferredWidth,
                        minWidth: minWidth,
                        maxWidth: maxWidth
                    )
                }
                return
            }

            guard let searchItem = window.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first else {
                return
            }

            configureWidth(
                for: searchItem,
                preferredWidth: preferredWidth,
                minWidth: minWidth,
                maxWidth: maxWidth
            )
        }

        private func configureWidth(
            for searchItem: NSSearchToolbarItem,
            preferredWidth: CGFloat,
            minWidth: CGFloat,
            maxWidth: CGFloat
        ) {
            let searchField = searchItem.searchField
            searchItem.preferredWidthForSearchField = preferredWidth

            searchField.constraints
                .filter { constraint in
                    constraint.identifier == Self.minConstraintIdentifier ||
                    constraint.identifier == Self.maxConstraintIdentifier
                }
                .forEach { $0.isActive = false }

            let minConstraint = searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth)
            minConstraint.identifier = Self.minConstraintIdentifier
            minConstraint.isActive = true

            let maxConstraint = searchField.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth)
            maxConstraint.identifier = Self.maxConstraintIdentifier
            maxConstraint.isActive = true
        }
    }
}
