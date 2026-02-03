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
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
