//
//  SettingsManager.swift
//  ClipVault
//
//  Created by Edd on 09/10/2025.
//

import Foundation
import AppKit

class SettingsManager {
    static let shared = SettingsManager()

    private let defaults: UserDefaults

    // UserDefaults Keys
    private enum Keys {
        static let imageStorageLimitMB = "imageStorageLimitMB"
        static let maxHistoryItems = "maxHistoryItems"
        static let captureText = "captureText"
        static let captureRTF = "captureRTF"
        static let autoPasteOnSelect = "autoPasteOnSelect"
        static let excludedAppBundleIDs = "excludedAppBundleIDs"
        static let contentFilterEnabled = "contentFilterEnabled"
        static let launchAtLogin = "launchAtLogin"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Set default values on first launch
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.maxHistoryItems: 100,
            Keys.imageStorageLimitMB: 1000,
            Keys.captureText: true,
            Keys.captureRTF: true,
            Keys.autoPasteOnSelect: false,
            Keys.excludedAppBundleIDs: [],
            Keys.contentFilterEnabled: true,
            Keys.launchAtLogin: false
        ])
    }

    // MARK: - General Settings

    var maxHistoryItems: Int {
        get { min(max(defaults.integer(forKey: Keys.maxHistoryItems), 1), 10_000) }
        set { defaults.set(min(max(newValue, 1), 10_000), forKey: Keys.maxHistoryItems) }
    }

    /// Decimal MB: 1000 MB is 1 GB. No unlimited setting.
    var imageStorageLimitMB: Int {
        get { min(max(defaults.object(forKey: Keys.imageStorageLimitMB) as? Int ?? 1000, 100), 100_000) }
        set { defaults.set(min(max(newValue, 100), 100_000), forKey: Keys.imageStorageLimitMB) }
    }

    var imageStorageLimitBytes: Int64 { Int64(imageStorageLimitMB) * 1_000_000 }

    var captureText: Bool {
        get { defaults.bool(forKey: Keys.captureText) }
        set { defaults.set(newValue, forKey: Keys.captureText) }
    }

    var captureRTF: Bool {
        get { defaults.bool(forKey: Keys.captureRTF) }
        set { defaults.set(newValue, forKey: Keys.captureRTF) }
    }

    var autoPasteOnSelect: Bool {
        get { defaults.bool(forKey: Keys.autoPasteOnSelect) }
        set { defaults.set(newValue, forKey: Keys.autoPasteOnSelect) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }

    // MARK: - Privacy Settings

    var excludedAppBundleIDs: [String] {
        get { defaults.stringArray(forKey: Keys.excludedAppBundleIDs) ?? [] }
        set { defaults.set(newValue, forKey: Keys.excludedAppBundleIDs) }
    }

    var contentFilterEnabled: Bool {
        get { defaults.bool(forKey: Keys.contentFilterEnabled) }
        set { defaults.set(newValue, forKey: Keys.contentFilterEnabled) }
    }

    func addExcludedApp(bundleID: String) {
        var excluded = excludedAppBundleIDs
        if !excluded.contains(bundleID) {
            excluded.append(bundleID)
            excludedAppBundleIDs = excluded
        }
    }

    func removeExcludedApp(bundleID: String) {
        var excluded = excludedAppBundleIDs
        excluded.removeAll { $0 == bundleID }
        excludedAppBundleIDs = excluded
    }

    // MARK: - Utility Methods

    func resetToDefaults() {
        maxHistoryItems = 100
        imageStorageLimitMB = 1000
        captureText = true
        captureRTF = true
        autoPasteOnSelect = false
        excludedAppBundleIDs = []
        contentFilterEnabled = true
        launchAtLogin = false
    }
}
