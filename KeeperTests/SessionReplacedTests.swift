import XCTest
@testable import Keepur

/// Protocol-level tests for the `session_replaced` message.
///
/// The beekeeper server sends a single `session_replaced` message when it
/// replaces one session with another at the same workspace path (e.g. server
/// restart, session migration). Unlike `context_cleared` (two-phase), this is
/// a single-phase atomic swap — the client receives old id, new id, and path
/// all in one message.
final class SessionReplacedTests: XCTestCase {

    // MARK: - Decode

    func testSessionReplacedDecodes() {
        let json: [String: Any] = [
            "type": "session_replaced",
            "oldSessionId": "sess-old",
            "newSessionId": "sess-new",
            "path": "/Users/test/project"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .sessionReplaced(let oldSessionId, let newSessionId, let path) = WSIncoming.decode(from: data) else {
            XCTFail("Expected sessionReplaced"); return
        }
        XCTAssertEqual(oldSessionId, "sess-old")
        XCTAssertEqual(newSessionId, "sess-new")
        XCTAssertEqual(path, "/Users/test/project")
    }

    func testSessionReplacedMissingOldSessionIdFails() {
        let json: [String: Any] = [
            "type": "session_replaced",
            "newSessionId": "sess-new",
            "path": "/Users/test/project"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        if case .sessionReplaced = WSIncoming.decode(from: data) {
            XCTFail("Should not decode as sessionReplaced without oldSessionId")
        }
    }

    func testSessionReplacedMissingNewSessionIdFails() {
        let json: [String: Any] = [
            "type": "session_replaced",
            "oldSessionId": "sess-old",
            "path": "/Users/test/project"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        if case .sessionReplaced = WSIncoming.decode(from: data) {
            XCTFail("Should not decode as sessionReplaced without newSessionId")
        }
    }

    func testSessionReplacedMissingPathFails() {
        let json: [String: Any] = [
            "type": "session_replaced",
            "oldSessionId": "sess-old",
            "newSessionId": "sess-new"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        if case .sessionReplaced = WSIncoming.decode(from: data) {
            XCTFail("Should not decode as sessionReplaced without path")
        }
    }
}
