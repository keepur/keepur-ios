import XCTest
import Security
@testable import Keepur

final class KeychainTransientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        KeychainManager.clearAll()
        UserDefaults.standard.removeObject(forKey: "keychain_accessibility_migrated_v1")
    }

    override func tearDown() {
        KeychainManager.clearAll()
        UserDefaults.standard.removeObject(forKey: "keychain_accessibility_migrated_v1")
        super.tearDown()
    }

    // MARK: - Keychain Accessibility

    func testSavedTokenUsesAfterFirstUnlockAccessibility() {
        KeychainManager.token = "test-token-123"

        // Query the raw Keychain item and check its accessibility attribute
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.keepur.beekeeper",
            kSecAttrAccount as String: "auth_token",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        XCTAssertEqual(status, errSecSuccess)

        guard let attrs = result as? [String: Any],
              let accessible = attrs[kSecAttrAccessible as String] as? String else {
            XCTFail("Could not read accessibility attribute"); return
        }

        XCTAssertEqual(accessible, kSecAttrAccessibleAfterFirstUnlock as String,
                        "Token should be stored with AfterFirstUnlock accessibility")
    }

    func testSavedTokenIsReadableAfterSave() {
        KeychainManager.token = "roundtrip-test"
        XCTAssertEqual(KeychainManager.token, "roundtrip-test")
    }

    // MARK: - Migration

    func testMigrateAccessibilityRunsOnce() {
        KeychainManager.token = "migrate-me"

        KeychainManager.migrateAccessibility()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "keychain_accessibility_migrated_v1"))

        // Token should still be readable after migration
        XCTAssertEqual(KeychainManager.token, "migrate-me")
    }

    func testMigrateAccessibilitySkipsWhenAlreadyMigrated() {
        UserDefaults.standard.set(true, forKey: "keychain_accessibility_migrated_v1")

        // Should not crash or alter data even if called again
        KeychainManager.migrateAccessibility()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "keychain_accessibility_migrated_v1"))
    }

    func testMigrateAccessibilityPreservesAllKeys() {
        KeychainManager.token = "tok-123"
        KeychainManager.deviceId = "dev-456"
        KeychainManager.deviceName = "My iPhone"

        KeychainManager.migrateAccessibility()

        XCTAssertEqual(KeychainManager.token, "tok-123")
        XCTAssertEqual(KeychainManager.deviceId, "dev-456")
        XCTAssertEqual(KeychainManager.deviceName, "My iPhone")
    }

    func testMigrateAccessibilityDoesNotMarkCompleteWhenEmpty() {
        // No items saved — migration should NOT mark complete so it retries next launch
        KeychainManager.migrateAccessibility()
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "keychain_accessibility_migrated_v1"))
    }

    // MARK: - Nil Token Doesn't Pair

    func testIsPairedReturnsFalseWhenNoToken() {
        XCTAssertFalse(KeychainManager.isPaired)
    }

    func testIsPairedReturnsTrueWhenTokenExists() {
        KeychainManager.token = "valid-token"
        XCTAssertTrue(KeychainManager.isPaired)
    }
}
