import XCTest
@testable import Keepur

/// Protocol-level tests for the `/clear` handoff (HIVE-113).
///
/// The beekeeper server splits a `/clear` into two WS messages:
///   1. `context_cleared` — both `oldSessionId` and `sessionId` are the OLD id,
///      signalling "wipe this session". Survives client disconnect via the
///      global buffer.
///   2. `session_info` — carries the NEW session id spawned by `newSession(cwd)`
///      on the same workspace path.
///
/// The client must treat `context_cleared` as a pure wipe and wait for the
/// follow-up `session_info` to adopt the new session.
final class ContextClearedTests: XCTestCase {

    // MARK: - Decode

    func testContextClearedDecodes() {
        let json: [String: Any] = [
            "type": "context_cleared",
            "oldSessionId": "sess-old",
            "sessionId": "sess-old"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .contextCleared(let oldSessionId, let sessionId) = WSIncoming.decode(from: data) else {
            XCTFail("Expected contextCleared"); return
        }
        XCTAssertEqual(oldSessionId, "sess-old")
        XCTAssertEqual(sessionId, "sess-old",
                       "Server sends the OLD id in both fields; new id arrives via session_info")
    }

    func testContextClearedMissingOldSessionIdFails() {
        let json: [String: Any] = [
            "type": "context_cleared",
            "sessionId": "sess-old"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        // Missing required field — should fall through to .unknown, not crash.
        if case .contextCleared = WSIncoming.decode(from: data) {
            XCTFail("Should not decode as contextCleared without oldSessionId")
        }
    }

    func testContextClearedMissingSessionIdFails() {
        let json: [String: Any] = [
            "type": "context_cleared",
            "oldSessionId": "sess-old"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        if case .contextCleared = WSIncoming.decode(from: data) {
            XCTFail("Should not decode as contextCleared without sessionId")
        }
    }
}
