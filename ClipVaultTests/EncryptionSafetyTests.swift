import Foundation
import Security
import XCTest
@testable import ClipVault

@MainActor
final class EncryptionSafetyTests: XCTestCase {
    func testLockedKeychainNeverCreatesOrOverwritesKey() {
        var saved = false
        XCTAssertThrowsError(try EncryptionManager.loadOrCreateKeyData(load: {
            throw EncryptionManager.EncryptionError.keychainError(errSecInteractionNotAllowed)
        }, save: { _ in saved = true }))
        XCTAssertFalse(saved)
    }

    func testInvalidExistingKeyIsPreservedAndReported() {
        var saved = false
        XCTAssertThrowsError(try EncryptionManager.loadOrCreateKeyData(load: { Data([1]) }, save: { _ in saved = true }))
        XCTAssertFalse(saved)
    }

    func testMissingKeyCreates256BitKey() throws {
        var saved: Data?
        let key = try EncryptionManager.loadOrCreateKeyData(load: {
            throw EncryptionManager.EncryptionError.keyNotFound
        }, save: { saved = $0 })
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(saved, key)
    }

    func testConcurrentCreationUsesExistingKey() throws {
        let existing = Data(repeating: 7, count: 32)
        var loads = 0
        let key = try EncryptionManager.loadOrCreateKeyData(load: {
            loads += 1
            if loads == 1 { throw EncryptionManager.EncryptionError.keyNotFound }
            return existing
        }, save: { _ in throw EncryptionManager.EncryptionError.keychainError(errSecDuplicateItem) })
        XCTAssertEqual(key, existing)
    }

    func testEncryptionRejectsTamperingAndUsesFreshNonces() throws {
        let data = Data("clipboard security test".utf8)
        let first = try EncryptionManager.shared.encrypt(data)
        let second = try EncryptionManager.shared.encrypt(data)
        XCTAssertNotEqual(first, second)
        var tampered = first
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try EncryptionManager.shared.decrypt(tampered))
        XCTAssertEqual(try EncryptionManager.shared.decrypt(second), data)
    }
}
