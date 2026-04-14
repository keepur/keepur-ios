import XCTest
@testable import Keepur

final class BeekeeperConfigTests: XCTestCase {
    override func setUp() {
        super.setUp()
        BeekeeperConfig.host = nil
    }

    override func tearDown() {
        BeekeeperConfig.host = nil
        super.tearDown()
    }

    // MARK: - validate

    func testValidateAcceptsPlainHostname() {
        XCTAssertEqual(BeekeeperConfig.validate("beekeeper.example.com"), "beekeeper.example.com")
    }

    func testValidateAcceptsHostnameWithPort() {
        XCTAssertEqual(BeekeeperConfig.validate("bee.example.com:8443"), "bee.example.com:8443")
    }

    func testValidateTrimsAndLowercases() {
        XCTAssertEqual(BeekeeperConfig.validate("  Bee.Example.COM  "), "bee.example.com")
    }

    func testValidateRejectsScheme() {
        XCTAssertNil(BeekeeperConfig.validate("https://beekeeper.example.com"))
        XCTAssertNil(BeekeeperConfig.validate("http://beekeeper.example.com"))
        XCTAssertNil(BeekeeperConfig.validate("wss://beekeeper.example.com"))
    }

    func testValidateRejectsPath() {
        XCTAssertNil(BeekeeperConfig.validate("beekeeper.example.com/pair"))
    }

    func testValidateRejectsWhitespace() {
        XCTAssertNil(BeekeeperConfig.validate("bee keeper.example.com"))
    }

    func testValidateRejectsEmpty() {
        XCTAssertNil(BeekeeperConfig.validate(""))
        XCTAssertNil(BeekeeperConfig.validate("   "))
    }

    func testValidateRejectsPortOutOfRange() {
        XCTAssertNil(BeekeeperConfig.validate("bee.example.com:0"))
        XCTAssertNil(BeekeeperConfig.validate("bee.example.com:65536"))
        XCTAssertNil(BeekeeperConfig.validate("bee.example.com:99999"))
    }

    func testValidateAcceptsPortBoundaries() {
        XCTAssertEqual(BeekeeperConfig.validate("bee.example.com:1"), "bee.example.com:1")
        XCTAssertEqual(BeekeeperConfig.validate("bee.example.com:65535"), "bee.example.com:65535")
    }

    // MARK: - URL builders

    func testHttpsURLThrowsWhenUnconfigured() {
        XCTAssertThrowsError(try BeekeeperConfig.httpsURL()) { error in
            XCTAssertEqual(error as? BeekeeperConfigError, .hostNotConfigured)
        }
    }

    func testWssURLThrowsWhenUnconfigured() {
        XCTAssertThrowsError(try BeekeeperConfig.wssURL()) { error in
            XCTAssertEqual(error as? BeekeeperConfigError, .hostNotConfigured)
        }
    }

    func testHttpsURLReturnsConfiguredHost() throws {
        BeekeeperConfig.host = "bee.example.com"
        XCTAssertEqual(try BeekeeperConfig.httpsURL().absoluteString, "https://bee.example.com")
    }

    func testWssURLReturnsConfiguredHost() throws {
        BeekeeperConfig.host = "bee.example.com:8443"
        XCTAssertEqual(try BeekeeperConfig.wssURL().absoluteString, "wss://bee.example.com:8443")
    }
}

// MARK: - Migration Tests

final class BeekeeperConfigMigrationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Full reset: clear both token and host so each test starts clean.
        KeychainManager.token = nil
        BeekeeperConfig.host = nil
    }

    override func tearDown() {
        KeychainManager.token = nil
        BeekeeperConfig.host = nil
        super.tearDown()
    }

    // MARK: - migrateIfNeeded

    func testMigrateIfNeededClearsTokenWhenHostIsNilButTokenExists() {
        // Seed: legacy install — token present, host absent.
        KeychainManager.token = "legacy-token"
        XCTAssertNil(BeekeeperConfig.host)

        BeekeeperConfig.migrateIfNeeded()

        XCTAssertNil(KeychainManager.token,
                     "migrateIfNeeded should clear the token when host is not configured")
    }

    func testMigrateIfNeededLeavesTokenWhenHostIsConfigured() {
        // Seed: normal install — both token and host present.
        KeychainManager.token = "valid-token"
        BeekeeperConfig.host = "bee.example.com"

        BeekeeperConfig.migrateIfNeeded()

        XCTAssertEqual(KeychainManager.token, "valid-token",
                       "migrateIfNeeded should not touch the token when host is configured")
    }

    func testMigrateIfNeededIsNoOpWhenTokenIsNil() {
        // Seed: fresh install — neither token nor host.
        XCTAssertNil(KeychainManager.token)
        XCTAssertNil(BeekeeperConfig.host)

        BeekeeperConfig.migrateIfNeeded()

        // Both should remain nil; no crash or side effects.
        XCTAssertNil(KeychainManager.token,
                     "migrateIfNeeded should be a no-op when no token is present")
        XCTAssertNil(BeekeeperConfig.host,
                     "migrateIfNeeded should not alter host when no token is present")
    }

    // MARK: - clearAll host side-effect

    func testClearAllAlsoClearsBeekeeperConfigHost() {
        // Seed: configure both token and host.
        KeychainManager.token = "test-token"
        BeekeeperConfig.host = "bee.example.com"

        KeychainManager.clearAll()

        XCTAssertNil(BeekeeperConfig.host,
                     "KeychainManager.clearAll() should also clear BeekeeperConfig.host")
        XCTAssertNil(KeychainManager.token,
                     "KeychainManager.clearAll() should clear the token")
    }
}
