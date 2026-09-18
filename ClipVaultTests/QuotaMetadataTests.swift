import AppKit
import CoreData
import XCTest
@testable import ClipVault

@MainActor
final class QuotaMetadataTests: XCTestCase {
    private func model(_ version: String = "ClipVaultV3") throws -> NSManagedObjectModel {
        let directory = try XCTUnwrap(Bundle(for: ClipItem.self).url(forResource: "ClipVault", withExtension: "momd"))
        return try XCTUnwrap(NSManagedObjectModel(contentsOf: directory.appendingPathComponent("\(version).mom")))
    }

    private func context() throws -> NSManagedObjectContext {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: try model())
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    private func image(_ byte: UInt8, manager: ClipItemManager, count: Int = 100) throws -> ClipItem {
        try manager.saveClipItem(content: .image(data: Data(repeating: byte, count: count), type: .png), appBundleID: "test.image.source")
    }

    func testDefaultIsOneDecimalGBAndInvalidLimitsAreClamped() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        XCTAssertEqual(settings.imageStorageLimitBytes, 1_000_000_000)
        settings.imageStorageLimitMB = -1
        XCTAssertEqual(settings.imageStorageLimitMB, 100)
        settings.imageStorageLimitMB = Int.max
        XCTAssertEqual(settings.imageStorageLimitMB, 100_000)
        settings.resetToDefaults()
        XCTAssertEqual(settings.imageStorageLimitMB, 1000)
    }

    func testExactLimitAndFIFOAgeSurviveRecopy() throws {
        let manager = ClipItemManager(context: try context(), imageLimitBytes: 256)
        let first = try image(1, manager: manager)
        let firstID = try XCTUnwrap(first.id)
        var metadata = try first.readMetadata()
        metadata.firstCapturedAt = Date(timeIntervalSince1970: 1)
        try first.storeMetadata(metadata)
        try first.managedObjectContext?.save()
        let second = try image(2, manager: manager)
        let secondID = try XCTUnwrap(second.id)
        XCTAssertEqual(try manager.imageStorageUsage(), 256)
        let duplicate = try image(1, manager: manager)
        XCTAssertEqual(duplicate.id, firstID)
        XCTAssertEqual(try duplicate.readMetadata().firstCapturedAt, Date(timeIntervalSince1970: 1))
        let thirdID = try XCTUnwrap(image(3, manager: manager).id)
        let ids = try manager.fetchAllItems().compactMap(\.id)
        XCTAssertFalse(ids.contains(firstID))
        XCTAssertTrue(ids.contains(secondID))
        XCTAssertTrue(ids.contains(thirdID))
        XCTAssertEqual(try manager.imageStorageUsage(), 256)
    }

    func testPinsAreCountedProtectedAndFullPinsRejectWithoutDeletingHistory() throws {
        let manager = ClipItemManager(context: try context(), imageLimitBytes: 256)
        let first = try image(1, manager: manager)
        try manager.togglePin(item: first)
        let second = try image(2, manager: manager)
        let secondID = try XCTUnwrap(second.id)
        let third = try image(3, manager: manager)
        XCTAssertFalse(try manager.fetchAllItems().compactMap(\.id).contains(secondID))
        try manager.togglePin(item: third)
        let before = Set(try manager.fetchAllItems().compactMap(\.id))
        XCTAssertThrowsError(try image(4, manager: manager))
        XCTAssertEqual(Set(try manager.fetchAllItems().compactMap(\.id)), before)
        XCTAssertEqual(try manager.imageStorageUsage(), 256)
    }

    func testTooLargeCaptureDoesNotEvictExistingImages() throws {
        let manager = ClipItemManager(context: try context(), imageLimitBytes: 256)
        _ = try image(1, manager: manager)
        let before = Set(try manager.fetchAllItems().compactMap(\.id))
        XCTAssertThrowsError(try image(2, manager: manager, count: 300))
        XCTAssertEqual(Set(try manager.fetchAllItems().compactMap(\.id)), before)
    }

    func testLowerLimitEvictsOldImagesButKeepsText() throws {
        let manager = ClipItemManager(context: try context(), imageLimitBytes: 256)
        _ = try image(1, manager: manager)
        _ = try image(2, manager: manager)
        let text = try manager.saveClipItem(content: .text("text remains"), appBundleID: "test")
        let textID = try XCTUnwrap(text.id)
        try manager.enforceImageStorageLimit(limitBytes: 128)
        XCTAssertEqual(try manager.imageStorageUsage(), 128)
        XCTAssertTrue(try manager.fetchAllItems().compactMap(\.id).contains(textID))
    }

    func testExistingOverLimitPinsRemainReadableAndBlockOnlyNewImages() throws {
        let context = try context()
        let original = ClipItemManager(context: context, imageLimitBytes: 256)
        let pin = try image(1, manager: original)
        try original.togglePin(item: pin)
        let lowered = ClipItemManager(context: context, imageLimitBytes: 100)
        XCTAssertEqual(try lowered.fetchAllItems().count, 1)
        XCTAssertThrowsError(try image(2, manager: lowered))
        _ = try lowered.saveClipItem(content: .text("still usable"), appBundleID: "test")
        XCTAssertEqual(try lowered.fetchAllItems().count, 2)
    }

    func testNewMetadataIsEncryptedAndHashesAreKeyDependent() throws {
        let manager = ClipItemManager(context: try context())
        let item = try manager.saveClipItem(content: .text("predictable text"), appBundleID: "secret.app.source")
        XCTAssertNil(item.appBundleID)
        XCTAssertNil(item.dateAdded)
        XCTAssertNil(item.imageType)
        XCTAssertEqual(item.sourceAppBundleID, "secret.app.source")
        XCTAssertNotNil(item.displayDate)
        XCTAssertTrue(item.contentHash?.hasPrefix("hmac1:") == true)
        XCTAssertNotEqual(item.contentHash, ClipItem.computeHash(for: "predictable text"))
        XCTAssertNil(try XCTUnwrap(item.encryptedMetadata).range(of: Data("secret.app.source".utf8)))
    }

    func testMetadataCannotBeSwappedBetweenClipsAndFailsClosed() throws {
        let manager = ClipItemManager(context: try context())
        let first = try manager.saveClipItem(content: .text("one"), appBundleID: "source.one")
        let second = try manager.saveClipItem(content: .text("two"), appBundleID: "source.two")
        second.encryptedMetadata = first.encryptedMetadata
        second.appBundleID = "plaintext fallback must not be used"
        XCTAssertThrowsError(try second.readMetadata())
        XCTAssertNil(second.sourceAppBundleID)
        second.managedObjectContext?.rollback()
    }

    func testFailedImageDecryptionPreservesCurrentPasteboard() throws {
        let manager = ClipItemManager(context: try context())
        let item = try image(1, manager: manager)
        item.encryptedMetadata = Data([0, 1])
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setString("existing clipboard", forType: .string)
        XCTAssertFalse(manager.writeToPasteboard(item, pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "existing clipboard")
    }

    func testFailedConversionDoesNotPartiallyModifyOtherRecords() throws {
        let context = try context()
        let first = NSEntityDescription.insertNewObject(forEntityName: "ClipItem", into: context) as! ClipItem
        first.id = UUID()
        first.contentHash = ClipItem.computeHash(for: "legacy one")
        first.appBundleID = "legacy.source"
        first.dateAdded = Date()
        try first.setEncryptedText("legacy one")
        let second = NSEntityDescription.insertNewObject(forEntityName: "ClipItem", into: context) as! ClipItem
        second.id = UUID()
        second.contentHash = ClipItem.computeHash(for: "legacy two")
        second.encryptedMetadata = Data([0])
        try second.setEncryptedText("legacy two")
        try context.save()
        XCTAssertThrowsError(try ClipItemManager.protectLegacyMetadata(in: context))
        XCTAssertNil(first.encryptedMetadata)
        XCTAssertEqual(first.appBundleID, "legacy.source")
        XCTAssertEqual(first.contentHash, ClipItem.computeHash(for: "legacy one"))
        XCTAssertFalse(context.hasChanges)
    }

    func testV2SQLiteMigrationPreservesContentPinsDatesAndDedupAndScrubsPlaintext() throws {
        try assertSQLiteMigration(from: "ClipVaultV2")
    }

    func testV1SQLiteMigrationPreservesContentPinsDatesAndDedupAndScrubsPlaintext() throws {
        try assertSQLiteMigration(from: "ClipVaultV1")
    }

    private func assertSQLiteMigration(from version: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.sqlite")
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let source = "unique.private.source.\(UUID().uuidString)"
        let text = "Existing private clip"
        let oldHash = ClipItem.computeHash(for: text)
        let ciphertext = try EncryptionManager.shared.encryptString(text)
        let old = NSPersistentStoreCoordinator(managedObjectModel: try model(version))
        let oldStore = try old.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = old
        let item = NSEntityDescription.insertNewObject(forEntityName: "ClipItem", into: oldContext)
        let id = UUID()
        item.setValue(id, forKey: "id")
        item.setValue(originalDate, forKey: "dateAdded")
        item.setValue(source, forKey: "appBundleID")
        item.setValue(oldHash, forKey: "contentHash")
        item.setValue(ciphertext, forKey: "textContent")
        item.setValue(true, forKey: "isPinned")
        try oldContext.save()
        oldContext.reset()
        try old.remove(oldStore)

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: try model())
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: ClipItemManager.storeOptions)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let manager = ClipItemManager(context: context)
        let migrated = try XCTUnwrap(manager.fetchAllItems().first)
        XCTAssertEqual(migrated.id, id)
        XCTAssertEqual(migrated.textContent, ciphertext)
        XCTAssertEqual(migrated.getDecryptedText(), text)
        XCTAssertEqual(migrated.sourceAppBundleID, source)
        XCTAssertEqual(migrated.displayDate, originalDate)
        XCTAssertTrue(migrated.isPinned)
        XCTAssertNil(migrated.appBundleID)
        XCTAssertNil(migrated.dateAdded)
        let duplicate = try manager.saveClipItem(content: .text(text), appBundleID: source)
        XCTAssertEqual(duplicate.id, id)
        XCTAssertEqual(try duplicate.readMetadata().firstCapturedAt, originalDate)
        context.reset()
        try coordinator.remove(store)
        let bytes = try Data(contentsOf: url)
        XCTAssertNil(bytes.range(of: Data(source.utf8)))
        XCTAssertNil(bytes.range(of: Data(oldHash.utf8)))
        // Core Data may leave an empty sidecar. Verify its contents too.
        for suffix in ["-wal", "-journal"] {
            if let sidecar = try? Data(contentsOf: URL(fileURLWithPath: url.path + suffix)) {
                XCTAssertNil(sidecar.range(of: Data(source.utf8)))
                XCTAssertNil(sidecar.range(of: Data(oldHash.utf8)))
            }
        }
        let reopened = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: ClipItemManager.storeOptions)
        let restored = try XCTUnwrap(ClipItemManager(context: context).fetchAllItems().first)
        XCTAssertEqual(restored.getDecryptedText(), text)
        XCTAssertEqual(restored.sourceAppBundleID, source)
        context.reset()
        try coordinator.remove(reopened)
    }

    func testSQLiteImageQuotaAndByteAccountingSurviveRelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("images.sqlite")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: try model())
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: ClipItemManager.storeOptions)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let manager = ClipItemManager(context: context, imageLimitBytes: 256)
        let first = try image(1, manager: manager)
        let firstID = try XCTUnwrap(first.id)
        _ = try image(2, manager: manager)
        _ = try image(3, manager: manager)
        XCTAssertEqual(try manager.imageStorageUsage(), 256)
        XCTAssertFalse(try manager.fetchAllItems().compactMap(\.id).contains(firstID))
        context.reset()
        try coordinator.remove(store)
        let reopened = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: ClipItemManager.storeOptions)
        let restarted = ClipItemManager(context: context, imageLimitBytes: 256)
        XCTAssertEqual(try restarted.imageStorageUsage(), 256)
        XCTAssertEqual(try restarted.fetchAllItems().count, 2)
        XCTAssertTrue(try restarted.fetchAllItems().allSatisfy { $0.getDecryptedImage()?.data.count == 100 })
        context.reset()
        try coordinator.remove(reopened)
    }


    func testChangingHashIndexIsDetectedEvenWithCachedMetadata() throws {
        let manager = ClipItemManager(context: try context())
        let first = try manager.saveClipItem(content: .text("one"), appBundleID: "source.one")
        let second = try manager.saveClipItem(content: .text("two"), appBundleID: "source.two")
        _ = try first.readMetadata()
        first.contentHash = second.contentHash
        XCTAssertThrowsError(try first.readMetadata())
        first.managedObjectContext?.rollback()
    }

    func testChangingImageByteCounterIsDetected() throws {
        let manager = ClipItemManager(context: try context(), imageLimitBytes: 256)
        let item = try image(1, manager: manager)
        item.imageByteCount = 1
        try item.managedObjectContext?.save()
        XCTAssertThrowsError(try manager.imageStorageUsage())
    }

}
