//
//  MercuryApp.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import SwiftUI

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
                Button("Search Entries") {
                    NotificationCenter.default.post(name: .focusSearchFieldCommand, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])
            }

            CommandMenu("Reader") {
                Button("Font Size Smaller") {
                    NotificationCenter.default.post(name: .readerFontSizeDecreaseCommand, object: nil)
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button("Font Size Larger") {
                    NotificationCenter.default.post(name: .readerFontSizeIncreaseCommand, object: nil)
                }
                .keyboardShortcut("=", modifiers: [.command])

                Divider()

                Button("Reset Reader Preview Overrides") {
                    NotificationCenter.default.post(name: .readerFontSizeResetCommand, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

extension Notification.Name {
    static let focusSearchFieldCommand = Notification.Name("focusSearchFieldCommand")
    static let readerFontSizeDecreaseCommand = Notification.Name("readerFontSizeDecreaseCommand")
    static let readerFontSizeIncreaseCommand = Notification.Name("readerFontSizeIncreaseCommand")
    static let readerFontSizeResetCommand = Notification.Name("readerFontSizeResetCommand")
}
