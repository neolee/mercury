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
        let bundle = LanguageManager.shared.bundle

        WindowGroup {
            ContentView()
                .environmentObject(appModel)
        }
        .commands {
            // "Check for Updates…" appears immediately after "About Mercury" in the app menu.
            CommandGroup(after: .appInfo) {
                Button(String(localized: "Check for Updates…", bundle: bundle)) {
                    appDelegate.updaterController.updater.checkForUpdates()
                }
            }

            // Replace the default (empty) Help menu with a link to the online README.
            CommandGroup(replacing: .help) {
                Button(String(localized: "Mercury Help", bundle: bundle)) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/neolee/mercury#readme")!)
                }
            }
        }

        Settings {
            AppSettingsView()
                .environmentObject(appModel)
        }
        .commands {
            CommandMenu(String(localized: "Search", bundle: bundle)) {
                Button(String(localized: "Search Entries", bundle: bundle)) {
                    NotificationCenter.default.post(name: .focusSearchFieldCommand, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])
            }

            CommandMenu(String(localized: "Reader", bundle: bundle)) {
                Button(String(localized: "Font Size Smaller", bundle: bundle)) {
                    NotificationCenter.default.post(name: .readerFontSizeDecreaseCommand, object: nil)
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button(String(localized: "Font Size Larger", bundle: bundle)) {
                    NotificationCenter.default.post(name: .readerFontSizeIncreaseCommand, object: nil)
                }
                .keyboardShortcut("=", modifiers: [.command])

                Divider()

                Button(String(localized: "Reset Theme Overrides", bundle: bundle)) {
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
