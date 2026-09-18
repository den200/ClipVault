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
        let item = NSEntityDescription.insertNewObject(forEntityName: "ClipItem", into: context) as! ClipItem

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

    func testMalformedImageDoesNotBecomeMetadataText() {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setData(Data([0, 1, 2]), forType: .png)
        pasteboard.setString("https://example.com/image", forType: .string)
        XCTAssertTrue(ClipboardMonitor.hasImageRepresentation(on: pasteboard))
        XCTAssertNil(ClipboardMonitor.imageContent(from: pasteboard))
    }

    func testCaptureFallsBackToValidRepresentation() {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setData(Data([0]), forType: .png)
        let tiff = NSImage(data: onePixelPNG)!.tiffRepresentation!
        pasteboard.setData(tiff, forType: .tiff)
        guard case let .image(data, type) = ClipboardMonitor.imageContent(from: pasteboard) else {
            return XCTFail("Expected valid TIFF fallback")
        }
        XCTAssertEqual(type, .tiff)
        XCTAssertEqual(data, tiff)
    }

    func testJPEGAndTIFFCaptureAndRestoration() throws {
        let bitmap = NSBitmapImageRep(data: onePixelPNG)!
        for (format, type) in [(NSBitmapImageRep.FileType.jpeg, NSPasteboard.PasteboardType("public.jpeg")), (.tiff, .tiff)] {
            let data = bitmap.representation(using: format, properties: [:])!
            let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
            pasteboard.clearContents()
            pasteboard.setData(data, forType: type)
            guard case let .image(captured, capturedType) = ClipboardMonitor.imageContent(from: pasteboard) else {
                return XCTFail("Expected image capture")
            }
            XCTAssertEqual(captured, data)
            XCTAssertEqual(capturedType, type)
            let item = try ClipItemManager.shared.saveClipItem(content: .image(data: captured, type: capturedType), appBundleID: "test")
            XCTAssertTrue(ClipItemManager.shared.writeToPasteboard(item, pasteboard: pasteboard))
            XCTAssertEqual(pasteboard.data(forType: capturedType), captured)
        }
    }

    func testImageDeduplicationSearchPinningAndDeletion() throws {
        let manager = ClipItemManager.shared
        let first = try manager.saveClipItem(content: .image(data: onePixelPNG, type: .png), appBundleID: "test")
        let duplicate = try manager.saveClipItem(content: .image(data: onePixelPNG, type: .png), appBundleID: "test")
        XCTAssertEqual(first.objectID, duplicate.objectID)
        XCTAssertFalse(try manager.searchItems(query: "Image").contains(first))
        try manager.togglePin(item: first)
        XCTAssertTrue(first.isPinned)
        let id = first.objectID
        try manager.deleteItem(first)
        XCTAssertFalse(try manager.fetchAllItems().contains { $0.objectID == id })
    }

    func testThumbnailPreservesAspectRatioAndSize() throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = bitmap.representation(using: .png, properties: [:])!
        let item = try ClipItemManager.shared.saveClipItem(content: .image(data: data, type: .png), appBundleID: "test")
        let thumbnail = try XCTUnwrap(item.getImageThumbnail(maxPixelSize: 160))
        XCTAssertLessThanOrEqual(thumbnail.size.width, 160)
        XCTAssertEqual(thumbnail.size.width / thumbnail.size.height, 2, accuracy: 0.01)
    }

    func testExistingDatabaseMigratesAndRetainsTextAndRTF() throws {
        let bundle = Bundle(for: ClipItem.self)
        let directory = try XCTUnwrap(bundle.url(forResource: "ClipVault", withExtension: "momd"))
        let old = try XCTUnwrap(NSManagedObjectModel(contentsOf: directory.appendingPathComponent("ClipVaultV1.mom")))
        let current = try XCTUnwrap(NSManagedObjectModel(contentsOf: directory.appendingPathComponent("ClipVaultV2.mom")))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.sqlite")
        let encryptedText = try EncryptionManager.shared.encryptString("Existing text")
        let rtf = NSAttributedString(string: "Existing text").rtf(from: NSRange(location: 0, length: 13), documentAttributes: [:])!
        let encryptedRTF = try EncryptionManager.shared.encrypt(rtf)
        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: old)
        let store = try oldCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = oldCoordinator
        let entity = NSEntityDescription.insertNewObject(forEntityName: "ClipItem", into: context)
        entity.setValue(UUID(), forKey: "id")
        entity.setValue(Date(), forKey: "dateAdded")
        entity.setValue("migration-test", forKey: "contentHash")
        entity.setValue(encryptedText, forKey: "textContent")
        entity.setValue(encryptedRTF, forKey: "rtfData")
        entity.setValue(true, forKey: "isPinned")
        try context.save()
        context.reset()
        try oldCoordinator.remove(store)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: current)
        let migrated = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
        let migratedContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        migratedContext.persistentStoreCoordinator = coordinator
        let item = try XCTUnwrap(migratedContext.fetch(ClipItem.fetchAllRequest()).first)
        XCTAssertEqual(item.getDecryptedText(), "Existing text")
        XCTAssertEqual(item.getDecryptedRTF(), rtf)
        XCTAssertTrue(item.isPinned)
        XCTAssertNil(item.imageData)
        try item.setEncryptedImage(onePixelPNG, type: .png)
        try migratedContext.save()
        migratedContext.reset()
        try coordinator.remove(migrated)
        let reopened = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let restored = try XCTUnwrap(migratedContext.fetch(ClipItem.fetchAllRequest()).first)
        XCTAssertEqual(restored.getDecryptedImage()?.data, onePixelPNG)
        migratedContext.reset()
        try coordinator.remove(reopened)
    }


    func testCaptureDispatchCreatesOneImageAndSkipsRejectedMetadata() throws {
        let monitor = ClipboardMonitor.shared
        let originalCallback = monitor.onNewClipDetected
        defer { monitor.onNewClipDetected = originalCallback }
        var capturedItems: [ClipItem] = []
        monitor.onNewClipDetected = { capturedItems.append($0) }
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setData(onePixelPNG, forType: .png)
        pasteboard.setString("https://example.com/image-metadata", forType: .string)
        monitor.captureClipboard(from: pasteboard, appBundleID: "com.clipvault.tests")
        XCTAssertEqual(capturedItems.count, 1)
        XCTAssertTrue(try XCTUnwrap(capturedItems.first).isImage)
        XCTAssertNil(capturedItems.first?.textContent)
        let before = try ClipItemManager.shared.fetchAllItems().count
        pasteboard.clearContents()
        pasteboard.setData(Data([0, 1, 2]), forType: .png)
        pasteboard.setString("https://example.com/rejected-image-metadata", forType: .string)
        monitor.captureClipboard(from: pasteboard, appBundleID: "com.clipvault.tests")
        XCTAssertEqual(capturedItems.count, 1)
        XCTAssertEqual(try ClipItemManager.shared.fetchAllItems().count, before)
    }

}
