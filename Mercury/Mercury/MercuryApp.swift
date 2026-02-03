//
//  MercuryApp.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import SwiftUI

@main
struct MercuryApp: App {
    @StateObject private var appStore = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appStore)
        }
    }
}
