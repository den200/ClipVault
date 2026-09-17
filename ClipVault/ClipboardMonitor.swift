//
//  ClipboardMonitor.swift
//  ClipVault
//
//  Created by Edd on 09/10/2025.
//

import Foundation
import AppKit
import OSLog

class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var isMonitoring = false

    private let settings = SettingsManager.shared
    private let itemManager = ClipItemManager.shared
    private let exclusionManager = ExclusionManager.shared

    /// Protects the database and UI from pathological clipboard providers while
    /// still allowing large, full-resolution Retina screenshots.
    static let maximumImageSize = 50 * 1_024 * 1_024

    /// Prefer a lossless representation already supplied by the source. Reading
    /// raw data here avoids decoding an image during the 300 ms polling path.
    static let supportedImageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")
    ]

    // Callback invoked when a new clipboard item is detected and saved
    var onNewClipDetected: ((ClipItem) -> Void)?

    private init() {}

    deinit {
        stopMonitoring()
    }

    // MARK: - Public Methods

    /// Starts monitoring the clipboard for changes
    func startMonitoring(interval: TimeInterval = 0.3) {
        guard !isMonitoring else { return }

        // Initialize with current change count
        lastChangeCount = NSPasteboard.general.changeCount

        // Set up timer for polling
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkForClipboardChanges()
        }

        isMonitoring = true
        AppLogger.clipboard.info("Started monitoring (interval: \(interval, format: .fixed(precision: 1))s)")
    }

    /// Stops monitoring the clipboard
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
        AppLogger.clipboard.info("Stopped monitoring")
    }

    // MARK: - Private Methods

    private func checkForClipboardChanges() {
        let currentChangeCount = NSPasteboard.general.changeCount

        // Check if pasteboard has changed
        guard currentChangeCount != lastChangeCount else { return }

        lastChangeCount = currentChangeCount

        // Capture the new clipboard content
        captureClipboard()
    }

    private func captureClipboard() {
        let pasteboard = NSPasteboard.general

        // Get the frontmost application bundle ID
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let appBundleID = frontmostApp?.bundleIdentifier

        // Check if this app should be excluded
        if let bundleID = appBundleID, exclusionManager.shouldExclude(appBundleID: bundleID) {
            AppLogger.privacy.debug("Skipped capture: excluded app [\(bundleID, privacy: .public)]")
            return
        }

        // Try to capture different types based on settings and availability
        // PRIORITY ORDER: Image > RTF > Plain Text. An image item often also
        // advertises text or metadata; selecting one canonical image type avoids
        // duplicate captures and prevents that metadata becoming the clip.

        if let image = Self.imageContent(from: pasteboard) {
            do {
                let item = try itemManager.saveClipItem(content: image, appBundleID: appBundleID)
                onNewClipDetected?(item)
                AppLogger.clipboard.debug("Captured image (app: \(appBundleID ?? "unknown", privacy: .public))")
            } catch {
                AppLogger.clipboard.error("Failed to save image item: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Priority 1: RTF (preserves formatting like bold, italic, colors)
        else if settings.captureRTF, let rtfData = pasteboard.data(forType: .rtf), !rtfData.isEmpty {
            do {
                // Extract plain text from RTF for preview and search
                let plainText: String
                if let attributedString = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
                    plainText = attributedString.string
                } else {
                    // Fallback: try to get plain text from pasteboard
                    plainText = pasteboard.string(forType: .string) ?? "[Rich Text]"
                }

                // Check if plain text content should be filtered
                if settings.contentFilterEnabled, exclusionManager.isLikelySensitive(content: plainText) {
                    AppLogger.privacy.debug("Skipped capture: sensitive content detected (RTF)")
                    return
                }

                let item = try itemManager.saveClipItem(
                    content: .rtf(plainText: plainText, rtfData: rtfData),
                    appBundleID: appBundleID
                )
                onNewClipDetected?(item)
                AppLogger.clipboard.debug("Captured RTF (bytes: \(rtfData.count), chars: \(plainText.count), app: \(appBundleID ?? "unknown", privacy: .public))")
            } catch {
                AppLogger.clipboard.error("Failed to save RTF item: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Priority 2: Plain text (only if RTF not available)
        else if settings.captureText, let string = pasteboard.string(forType: .string), !string.isEmpty {
            // Check if content should be filtered
            if settings.contentFilterEnabled, exclusionManager.isLikelySensitive(content: string) {
                AppLogger.privacy.debug("Skipped capture: sensitive content detected (text)")
                return
            }

            do {
                let item = try itemManager.saveClipItem(
                    content: .text(string),
                    appBundleID: appBundleID
                )
                onNewClipDetected?(item)
                AppLogger.clipboard.debug("Captured text (chars: \(string.count), app: \(appBundleID ?? "unknown", privacy: .public))")
            } catch {
                AppLogger.clipboard.error("Failed to save text item: \(error.localizedDescription, privacy: .public)")
            }
        }
        else {
            AppLogger.clipboard.debug("Skipped capture: no supported content or capture disabled")
        }
    }

    /// Returns at most one image representation, in a stable preference order.
    /// Data over the limit is ignored rather than decoded or persisted.
    static func imageContent(from pasteboard: NSPasteboard) -> ClipContent? {
        for type in supportedImageTypes where pasteboard.availableType(from: [type]) != nil {
            guard let data = pasteboard.data(forType: type), !data.isEmpty else { continue }
            guard data.count <= maximumImageSize else {
                AppLogger.clipboard.notice("Skipped image larger than \(maximumImageSize) bytes")
                return nil
            }
            return .image(data: data, type: type)
        }
        return nil
    }
}
