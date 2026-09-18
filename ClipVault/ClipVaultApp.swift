//
//  ClipVaultApp.swift
//  ClipVault
//
//  Created by Edd on 09/10/2025.
//

import SwiftUI

@main
struct ClipVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Hidden window keeps SwiftUI lifecycle alive for Settings scene
        WindowGroup("ClipVaultLifecycle") {
            HiddenWindowView()
        }
        .defaultSize(width: 320, height: 200)

        // Native macOS Settings scene
        Settings {
            SettingsView()
        }
    }
}
