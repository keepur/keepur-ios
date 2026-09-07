import XCTest
import SwiftUI
@testable import Keepur

/// Pure mapping tests for `KeepurConnectionBanner.Presentation.make(state:error:)`
/// (spec §3 table) plus a `body` smoke for every row. @MainActor because
/// `BeekeeperSocket.State` and the mapping live in the MainActor-isolated app target.
@MainActor
final class KeepurConnectionBannerTests: XCTestCase {
    private typealias P = KeepurConnectionBanner.Presentation

    func testConnectedWithoutErrorRendersNothing() {
        XCTAssertNil(P.make(state: .connected, error: nil))
    }

    func testConnecting() throws {
        let p = try XCTUnwrap(P.make(state: .connecting, error: nil))
        XCTAssertEqual(p.text, "Connecting…")
        XCTAssertNil(p.actionTitle)
        XCTAssertEqual(p.tint, .warning)
        XCTAssertEqual(p.accessibilityLabel, "Connecting")
        XCTAssertFalse(p.dismissesOnTap)
    }

    func testReconnectingKeepsAttemptOutOfVisibleText() throws {
        let p = try XCTUnwrap(P.make(state: .reconnecting(attempt: 3), error: nil))
        XCTAssertEqual(p.text, "Reconnecting…")
        XCTAssertEqual(p.actionTitle, "Retry now")
        XCTAssertEqual(p.tint, .warning)
        XCTAssertTrue(p.accessibilityLabel.contains("attempt 3"))
        XCTAssertFalse(p.text.contains("3"), "attempt count is accessibility-only")
    }

    func testDisconnected() throws {
        let p = try XCTUnwrap(P.make(state: .disconnected, error: nil))
        XCTAssertEqual(p.text, "Not connected. Messages will send when reconnected.")
        XCTAssertEqual(p.actionTitle, "Retry")
        XCTAssertEqual(p.tint, .danger)
        XCTAssertEqual(p.accessibilityLabel, p.text)
        XCTAssertFalse(p.dismissesOnTap)
    }

    func testErrorWinsInEveryStateAndKeepsTheStateAction() throws {
        let error = UserFacingError("boom")
        let states: [BeekeeperSocket.State] = [.connected, .connecting, .reconnecting(attempt: 2), .disconnected]
        for state in states {
            let p = try XCTUnwrap(P.make(state: state, error: error), "\(state)")
            XCTAssertEqual(p.text, "boom", "\(state)")
            XCTAssertEqual(p.tint, .danger, "\(state)")
            XCTAssertTrue(p.dismissesOnTap, "\(state)")
            XCTAssertEqual(p.actionTitle, P.make(state: state, error: nil)?.actionTitle,
                           "\(state): the action is unchanged from the nil-error row")
            XCTAssertTrue(p.accessibilityLabel.hasPrefix("boom"), "\(state)")
        }
        XCTAssertEqual(try XCTUnwrap(P.make(state: .reconnecting(attempt: 2), error: error)).accessibilityLabel,
                       "boom. Reconnecting, attempt 2")
        XCTAssertEqual(try XCTUnwrap(P.make(state: .disconnected, error: error)).accessibilityLabel,
                       "boom. Not connected.")
    }

    func testBannerInstantiatesForEveryRow() {
        let error = UserFacingError("boom")
        var presentations: [P?] = [nil]
        for state in [BeekeeperSocket.State.connected, .connecting, .reconnecting(attempt: 1), .disconnected] {
            presentations.append(P.make(state: state, error: nil))
            presentations.append(P.make(state: state, error: error))
        }
        for p in presentations {
            _ = KeepurConnectionBanner(presentation: p, onRetry: {}, onDismissError: {}).body
        }
    }
}
