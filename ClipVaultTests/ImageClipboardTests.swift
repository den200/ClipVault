import AppKit
import CoreData
import XCTest
@testable import ClipVault

@MainActor
final class ImageClipboardTests: XCTestCase {
    private let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    func testImageCapturePrefersPNGAndCreatesSingleContent() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setData(Data([0x49, 0x49]), forType: .tiff)
        pasteboard.setData(onePixelPNG, forType: .png)

        guard case let .image(data, type) = ClipboardMonitor.imageContent(from: pasteboard) else {
            return XCTFail("Expected image content")
        }
        XCTAssertEqual(type, .png)
        XCTAssertEqual(data, onePixelPNG)
    }

    func testImageCaptureRejectsOversizedPayload() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setData(Data(count: ClipboardMonitor.maximumImageSize + 1), forType: .png)

        XCTAssertNil(ClipboardMonitor.imageContent(from: pasteboard))
    }

    func testImageHashUsesStableBytes() {
        XCTAssertEqual(ClipItem.computeHash(for: onePixelPNG), ClipItem.computeHash(for: onePixelPNG))
        XCTAssertNotEqual(ClipItem.computeHash(for: onePixelPNG), ClipItem.computeHash(for: Data([0])))
    }

    func testImageEncryptionRoundTrip() throws {
        let encrypted = try EncryptionManager.shared.encrypt(onePixelPNG)
        XCTAssertNotEqual(encrypted, onePixelPNG)
        XCTAssertEqual(try EncryptionManager.shared.decrypt(encrypted), onePixelPNG)
    }

    func testImageRestorationUsesOriginalRepresentation() throws {
        let model = NSManagedObjectModel.mergedModel(from: [Bundle(for: ClipItem.self)])!
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(
            ofType: NSInMemoryStoreType,
            configurationName: nil,
            at: nil
        )
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let item = ClipItem(context: context)

        try item.setEncryptedImage(onePixelPNG, type: .png)

        XCTAssertNotEqual(item.imageData, onePixelPNG)
        XCTAssertEqual(item.getDecryptedImage()?.data, onePixelPNG)
        XCTAssertEqual(item.getDecryptedImage()?.type, .png)
        XCTAssertNil(item.textContent)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        XCTAssertTrue(ClipItemManager.shared.writeToPasteboard(item, pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.data(forType: .png), onePixelPNG)
    }

    func testTextHashBehaviorRemainsStable() {
        XCTAssertEqual(ClipItem.computeHash(for: "hello"), ClipItem.computeHash(for: Data("hello".utf8)))
    }
}
