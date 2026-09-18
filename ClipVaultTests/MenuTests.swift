import AppKit
import XCTest
@testable import ClipVault

@MainActor
final class MenuTests: XCTestCase {
    func testHistoryActionsSurviveRepeatedSearchUpdates() {
        let delegate = AppDelegate()
        delegate.buildMainMenu()
        for query in ["no-match-12345", "", "Image", "", "no-match-12345", ""] {
            delegate.searchField.stringValue = query
            delegate.searchFieldTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: delegate.searchField))
            XCTAssertEqual(Array(delegate.menu.items.suffix(3)).map(\.title), ["Clipboard History", "Clear History…", "Settings"])
            XCTAssertTrue(delegate.menu.items[delegate.menu.items.count - 4].isSeparatorItem)
        }
        delegate.buildMainMenu()
        delegate.searchFieldTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: NSSearchField()))
        XCTAssertEqual(Array(delegate.menu.items.suffix(3)).map(\.title), ["Clipboard History", "Clear History…", "Settings"])
    }

    func testClearingHistoryPreservesPinnedClips() throws {
        let manager = ClipItemManager.shared
        let pinned = try manager.saveClipItem(content: .text("Pinned clear-history test \(UUID())"), appBundleID: "test")
        try manager.togglePin(item: pinned)
        _ = try manager.saveClipItem(content: .text("Unpinned clear-history test \(UUID())"), appBundleID: "test")
        try manager.clearHistory()
        let retained = try manager.fetchAllItems()
        XCTAssertTrue(retained.contains { $0.objectID == pinned.objectID })
        XCTAssertTrue(retained.allSatisfy { $0.isPinned })
        try manager.deleteItem(pinned)
    }

}
