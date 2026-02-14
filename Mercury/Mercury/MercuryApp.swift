//
//  MercuryApp.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import SwiftUI

extension Notification.Name {
    static let focusSearchFieldCommand = Notification.Name("Mercury.FocusSearchFieldCommand")
    static let cancelSearchFieldCommand = Notification.Name("Mercury.CancelSearchFieldCommand")
}

@main
struct MercuryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
        }
        .commands {
            CommandMenu("Search") {
                Button("Focus Search") {
                    NotificationCenter.default.post(name: .focusSearchFieldCommand, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("Cancel Search") {
                    NotificationCenter.default.post(name: .cancelSearchFieldCommand, object: nil)
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
