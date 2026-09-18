import Foundation
import CoreData
import AppKit
import OSLog

@MainActor
class ClipItemManager {
    static let shared = ClipItemManager()
    private let suppliedContext: NSManagedObjectContext?
    private let suppliedImageLimit: Int64?
    private var historyPrepared = false
    private let settings = SettingsManager.shared
    private let encryption = EncryptionManager.shared
    #if DEBUG
    private var useInMemoryStore = false
    #endif

    init(context: NSManagedObjectContext? = nil, imageLimitBytes: Int64? = nil) {
        suppliedContext = context
        suppliedImageLimit = imageLimitBytes
    }

    // DELETE journaling checkpoints legacy WALs. Secure-delete scrubs old cells
    // when plaintext metadata is replaced; startup compaction reclaims free pages.
    static let storeOptions: [String: NSObject] = [
        NSMigratePersistentStoresAutomaticallyOption: true as NSNumber,
        NSInferMappingModelAutomaticallyOption: true as NSNumber,
        NSSQLitePragmasOption: ["journal_mode": "DELETE", "secure_delete": "ON"] as NSDictionary,
        NSSQLiteManualVacuumOption: true as NSNumber
    ]

    private lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "ClipVault")
        for description in container.persistentStoreDescriptions {
            for (key, value) in Self.storeOptions {
                description.setOption(value, forKey: key)
            }
        }
        #if DEBUG
        if useInMemoryStore {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        }
        #endif
        container.loadPersistentStores { description, error in
            if let error {
                AppLogger.persistence.error("Failed to load persistent store: \(error.localizedDescription, privacy: .public)")
                fatalError("Unable to load persistent stores: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        // Do not silently merge away conflicting encryption or metadata writes.
        container.viewContext.mergePolicy = NSErrorMergePolicy
        return container
    }()

    private var context: NSManagedObjectContext { suppliedContext ?? persistentContainer.viewContext }
    private var imageLimit: Int64 { suppliedImageLimit ?? settings.imageStorageLimitBytes }

    #if DEBUG
    func configureForDemoMode() { useInMemoryStore = true }
    func getDemoContext() -> NSManagedObjectContext { context }
    #endif

    /// Prepare every ciphertext before changing any record, then commit once.
    /// Existing content ciphertext, IDs and pins are never rewritten here.
    static func protectLegacyMetadata(in context: NSManagedObjectContext) throws {
        let items = try context.fetch(ClipItem.fetchAllRequest())
        let legacy = items.filter { $0.encryptedMetadata == nil || !($0.contentHash ?? "").hasPrefix("hmac1:") }
        for item in legacy {
            if let payload = item.textContent ?? item.imageData ?? item.rtfData {
                _ = try EncryptionManager.shared.decrypt(payload)
                break
            }
        }
        let prepared = try legacy.map { item -> (ClipItem, Data, String, Int64) in
            guard let id = item.id, let hash = item.contentHash else { throw EncryptionManager.EncryptionError.invalidInput }
            var metadata = try item.readMetadata()
            metadata.imageByteCount = Int64(item.imageData?.count ?? 0)
            let protectedHash = hash.hasPrefix("hmac1:") ? hash : try EncryptionManager.shared.deduplicationHash(legacyHash: hash, isImage: item.isImage)
            metadata.contentHash = protectedHash
            let ciphertext = try EncryptionManager.shared.encryptMetadata(JSONEncoder().encode(metadata), itemID: id)
            return (item, ciphertext, protectedHash, Int64(item.imageData?.count ?? 0))
        }
        do {
            for (item, ciphertext, hash, bytes) in prepared {
                item.encryptedMetadata = ciphertext
                item.dateAdded = nil
                item.appBundleID = nil
                item.imageType = nil
                item.contentHash = hash
                item.imageByteCount = bytes
            }
            if context.hasChanges { try context.save() }
        } catch {
            context.rollback()
            throw error
        }
    }

    private func prepareHistory() throws {
        guard !historyPrepared else { return }
        try Self.protectLegacyMetadata(in: context)
        try enforceImageStorageLimit()
        historyPrepared = true
    }

    func saveClipItem(content: ClipContent, appBundleID: String?) throws -> ClipItem {
        try prepareHistory()
        let hash = try computeHash(for: content)
        if let existing = try context.fetch(ClipItem.fetchByHashRequest(hash: hash)).first {
            do {
                var metadata = try existing.readMetadata()
                metadata.dateAdded = Date()
                // FIFO age stays at the first capture, independent of recopying.
                try existing.storeMetadata(metadata)
                try context.save()
                return existing
            } catch { context.rollback(); throw error }
        }

        // Encrypt and preflight capacity before inserting or deleting anything.
        var text: Data?, rtf: Data?, image: Data?, imageType: String?
        switch content {
        case .text(let string): text = try encryption.encryptString(string)
        case .rtf(let plainText, let data):
            text = try encryption.encryptString(plainText)
            rtf = try encryption.encrypt(data)
        case .image(let data, let type):
            image = try encryption.encrypt(data)
            imageType = type.rawValue
        }
        let victims = image == nil ? [] : try imageEvictions(limit: imageLimit, reserving: Int64(image!.count))
        let item = NSEntityDescription.insertNewObject(forEntityName: "ClipItem", into: context) as! ClipItem
        do {
            item.id = UUID()
            item.isPinned = false
            item.contentHash = hash
            item.textContent = text
            item.rtfData = rtf
            item.imageData = image
            item.imageByteCount = Int64(image?.count ?? 0)
            let now = Date()
            try item.storeMetadata(ClipMetadata(dateAdded: now, firstCapturedAt: now, appBundleID: appBundleID, imageType: imageType, imageByteCount: Int64(image?.count ?? 0)))
            for id in victims { context.delete(context.object(with: id)) }
            try trimHistoryCount()
            try context.save()
            if !victims.isEmpty { ClipItem.clearThumbnailCache() }
            return item
        } catch { context.rollback(); throw error }
    }

    func fetchAllItems() throws -> [ClipItem] {
        try prepareHistory()
        let items = try context.fetch(ClipItem.fetchAllRequest())
        // Fail closed if protected metadata cannot be authenticated.
        let dated = try items.map { ($0, try $0.readMetadata().dateAdded ?? .distantPast) }
        return dated.sorted {
            if $0.0.isPinned != $1.0.isPinned { return $0.0.isPinned }
            return $0.1 > $1.1
        }.map { $0.0 }
    }

    func searchItems(query: String) throws -> [ClipItem] {
        try fetchAllItems().filter { $0.getDecryptedText()?.localizedCaseInsensitiveContains(query) == true }
    }

    func fetchMostRecentItem() throws -> ClipItem? {
        try fetchAllItems().max { ($0.displayDate ?? .distantPast) < ($1.displayDate ?? .distantPast) }
    }

    func togglePin(item: ClipItem) throws {
        try prepareHistory()
        do { item.isPinned.toggle(); try context.save() }
        catch { context.rollback(); throw error }
    }

    func deleteItem(_ item: ClipItem) throws {
        try prepareHistory()
        do { context.delete(item); try context.save(); ClipItem.clearThumbnailCache() }
        catch { context.rollback(); throw error }
    }

    func clearHistory() throws { try clearItems(includePins: false) }
    func clearAll() throws { try clearItems(includePins: true) }
    private func clearItems(includePins: Bool) throws {
        try prepareHistory()
        let request = ClipItem.fetchRequest()
        if !includePins { request.predicate = NSPredicate(format: "isPinned == NO") }
        do {
            for item in try context.fetch(request) { context.delete(item) }
            try context.save()
            ClipItem.clearThumbnailCache()
        } catch { context.rollback(); throw error }
    }

    func writeToPasteboard(_ item: ClipItem) -> Bool { writeToPasteboard(item, pasteboard: .general) }
    func writeToPasteboard(_ item: ClipItem, pasteboard: NSPasteboard) -> Bool {
        if item.isImage {
            guard let image = item.getDecryptedImage() else { return false }
            pasteboard.clearContents()
            return pasteboard.setData(image.data, forType: image.type)
        } else if let rtf = item.getDecryptedRTF() {
            pasteboard.clearContents()
            return pasteboard.setData(rtf, forType: .rtf)
        } else if let text = item.getDecryptedText() {
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
        return false
    }

    private struct ImageRecord {
        let objectID: NSManagedObjectID
        let bytes: Int64
        let pinned: Bool
        let firstCapturedAt: Date
    }

    /// Fetch metadata and byte counts without loading large image payloads.
    private func imageRecords() throws -> [ImageRecord] {
        let request = NSFetchRequest<NSDictionary>(entityName: "ClipItem")
        request.resultType = .dictionaryResultType
        request.predicate = NSPredicate(format: "imageByteCount > 0")
        let objectID = NSExpressionDescription()
        objectID.name = "recordID"
        objectID.expression = NSExpression.expressionForEvaluatedObject()
        objectID.expressionResultType = .objectIDAttributeType
        request.propertiesToFetch = [objectID, "id", "imageByteCount", "isPinned", "encryptedMetadata", "contentHash"]
        return try context.fetch(request).map { row in
            guard let objectID = row["recordID"] as? NSManagedObjectID,
                  let id = row["id"] as? UUID, let data = row["encryptedMetadata"] as? Data,
                  let bytes = row["imageByteCount"] as? NSNumber else { throw EncryptionManager.EncryptionError.invalidInput }
            let metadata = try JSONDecoder().decode(ClipMetadata.self, from: encryption.decryptMetadata(data, itemID: id))
            guard metadata.version == 1, metadata.contentHash == row["contentHash"] as? String, bytes.int64Value > 0, bytes.int64Value == metadata.imageByteCount, bytes.int64Value <= Int64(ClipboardMonitor.maximumImageSize) + 28 else { throw EncryptionManager.EncryptionError.invalidOutput }
            return ImageRecord(objectID: objectID, bytes: bytes.int64Value,
                pinned: (row["isPinned"] as? NSNumber)?.boolValue ?? false,
                firstCapturedAt: metadata.firstCapturedAt ?? metadata.dateAdded ?? .distantPast)
        }
    }

    private func imageEvictions(limit: Int64, reserving incoming: Int64 = 0, preserveExistingPins: Bool = false) throws -> [NSManagedObjectID] {
        let records = try imageRecords()
        let pinned = records.filter(\.pinned).reduce(Int64(0)) { $0 + $1.bytes }
        // Reject before deleting any older image if the new one cannot fit.
        guard incoming >= 0, incoming <= limit, (pinned <= limit - incoming || (preserveExistingPins && incoming == 0)) else { throw StorageError.pinnedCapacity }
        var used = records.reduce(Int64(0)) { $0 + $1.bytes } + incoming
        var victims: [NSManagedObjectID] = []
        for image in records.filter({ !$0.pinned }).sorted(by: {
            if $0.firstCapturedAt != $1.firstCapturedAt { return $0.firstCapturedAt < $1.firstCapturedAt }
            return $0.objectID.uriRepresentation().absoluteString < $1.objectID.uriRepresentation().absoluteString
        }) where used > limit {
            victims.append(image.objectID)
            used -= image.bytes
        }
        return victims
    }

    func imageStorageUsage() throws -> Int64 {
        try prepareHistory()
        return try imageRecords().reduce(0) { $0 + $1.bytes }
    }

    func enforceImageStorageLimit(limitBytes: Int64? = nil) throws {
        // Existing pins may exceed a newly introduced default: keep them usable,
        // evict unpinned images and block new captures until capacity is available.
        let victims = try imageEvictions(limit: limitBytes ?? imageLimit, preserveExistingPins: true)
        do {
            for id in victims { context.delete(context.object(with: id)) }
            if context.hasChanges { try context.save() }
            if !victims.isEmpty { ClipItem.clearThumbnailCache() }
        } catch { context.rollback(); throw error }
    }

    func setImageStorageLimit(megabytes: Int) throws {
        try prepareHistory()
        let normalized = min(max(megabytes, 100), 100_000)
        let victims = try imageEvictions(limit: Int64(normalized) * 1_000_000)
        do {
            for id in victims { context.delete(context.object(with: id)) }
            if context.hasChanges { try context.save() }
            settings.imageStorageLimitMB = normalized
            if !victims.isEmpty { ClipItem.clearThumbnailCache() }
        } catch { context.rollback(); throw error }
    }

    private func trimHistoryCount() throws {
        let items = try context.fetch(ClipItem.fetchAllRequest()).filter { !$0.isPinned }
        let dated = try items.map { ($0, try $0.readMetadata().dateAdded ?? .distantPast) }
        for item in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(settings.maxHistoryItems) { context.delete(item.0) }
    }

    private func computeHash(for content: ClipContent) throws -> String {
        switch content {
        case .text(let string), .rtf(let string, _):
            return try encryption.deduplicationHash(legacyHash: ClipItem.computeHash(for: string), isImage: false)
        case .image(let data, _):
            return try encryption.deduplicationHash(legacyHash: ClipItem.computeHash(for: data), isImage: true)
        }
    }

    enum StorageError: Error, LocalizedError {
        case pinnedCapacity
        var errorDescription: String? { "The image limit is too small for this image and your pinned images. Increase it or delete/unpin an image." }
    }
}

enum ClipContent {
    case text(String)
    case rtf(plainText: String, rtfData: Data)
    case image(data: Data, type: NSPasteboard.PasteboardType)
}
