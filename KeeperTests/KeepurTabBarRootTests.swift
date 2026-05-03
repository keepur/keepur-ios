import XCTest
import SwiftUI
@testable import Keepur

final class KeepurTabBarRootTests: XCTestCase {

    func testBeekeeperRootViewInstantiates() {
        _ = BeekeeperRootView().body
    }

    func testTabSymbolsResolve() {
        XCTAssertFalse(KeepurTheme.Symbol.bolt.isEmpty)
        XCTAssertFalse(KeepurTheme.Symbol.chat.isEmpty)
        XCTAssertFalse(KeepurTheme.Symbol.settings.isEmpty)
    }
}
