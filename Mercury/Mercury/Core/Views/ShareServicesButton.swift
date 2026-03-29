import AppKit
import SwiftUI

struct ShareServicesButton: NSViewRepresentable {
    let title: String
    let isEnabled: Bool
    let prepareItems: @MainActor () async -> [Any]

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.performShare(_:)))
        button.bezelStyle = .rounded
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.title = title
        nsView.isEnabled = isEnabled
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: ShareServicesButton

        init(_ parent: ShareServicesButton) {
            self.parent = parent
        }

        @MainActor
        @objc func performShare(_ sender: NSButton) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let items = await parent.prepareItems()
                guard items.isEmpty == false else { return }
                let picker = NSSharingServicePicker(items: items)
                picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
            }
        }
    }
}
