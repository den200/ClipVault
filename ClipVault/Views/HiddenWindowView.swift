//
//  HiddenWindowView.swift
//  ClipVault
//
//  Created by Edd on 02/01/2026.
//

import SwiftUI

/// Notification to open settings from anywhere in the app
extension Notification.Name {
    static let openClipVaultSettings = Notification.Name("openClipVaultSettings")
}

/// Invisible view that keeps SwiftUI's lifecycle alive for the Settings scene.
/// This window is positioned off-screen and made completely invisible.
struct HiddenWindowView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(minWidth: 320, minHeight: 200)
            .onReceive(NotificationCenter.default.publisher(for: .openClipVaultSettings)) { _ in
                openSettings()
            }
            .onAppear {
                // Find and hide the lifecycle window
                DispatchQueue.main.async {
                    for window in NSApp.windows where window.title == "ClipVaultLifecycle" {
                        // Keep SwiftUI's normal hosting-window geometry. Mutating
                        // styleMask or forcing a 1-point content size during layout
                        // can cause an endless constraints update on recent macOS.
                        window.isExcludedFromWindowsMenu = true
                        window.alphaValue = 0
                        window.ignoresMouseEvents = true
                        window.orderOut(nil)
                        break
                    }
                }
            }
    }
}
