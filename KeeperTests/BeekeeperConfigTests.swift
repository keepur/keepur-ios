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
