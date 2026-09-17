import XCTest
@testable import ClipVault

@MainActor
final class CrashHardeningTests: XCTestCase {
    func testHistoryLimitIsClampedBeforeCollectionIndexing() {
        let settings = SettingsManager.shared
        let original = settings.maxHistoryItems
        defer { settings.maxHistoryItems = original }

        settings.maxHistoryItems = -1
        XCTAssertEqual(settings.maxHistoryItems, 1)

        settings.maxHistoryItems = 20_000
        XCTAssertEqual(settings.maxHistoryItems, 10_000)
    }
}
