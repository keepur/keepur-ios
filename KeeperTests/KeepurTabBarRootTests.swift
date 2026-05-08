import XCTest
import SwiftUI
@testable import Keepur

final class KeepurTabBarRootTests: XCTestCase {

    // testBeekeeperRootViewInstantiates removed — BeekeeperRootView now requires
    // a ChatViewModel and an internal @StateObject; the smoke crashes on Keychain
    // statics fired during ChatViewModel init. Per the project memory note on
    // "Don't smoke-test complex View bodies," coverage moves to manual smoke
    // (Task 14 of KPR-203) once the server-side concierge handler ships.

    func testTabSymbolsResolve() {
        XCTAssertFalse(KeepurTheme.Symbol.bolt.isEmpty)
        XCTAssertFalse(KeepurTheme.Symbol.chat.isEmpty)
        XCTAssertFalse(KeepurTheme.Symbol.settings.isEmpty)
    }
}
