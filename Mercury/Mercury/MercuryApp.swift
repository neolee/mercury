//
//  MercuryApp.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Sparkle
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
            // "Check for Updates…" appears immediately after "About Mercury" in the app menu.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates\u{2026}") {
                    appDelegate.updaterController.updater.checkForUpdates()
                }
            }

            // Replace the default (empty) Help menu with a link to the online README.
            CommandGroup(replacing: .help) {
                Button("Mercury Help") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/neolee/mercury#readme")!)
                }
            }
        }

        Settings {
            AppSettingsView()
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

                Button("Reset Theme Overrides") {
                    NotificationCenter.default.post(name: .readerFontSizeResetCommand, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    // Sparkle auto-updater. Declared here so it lives as long as the application
    // delegate and is accessible from command handlers in MercuryApp.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

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
