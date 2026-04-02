import XCTest
@testable import Keepur

final class BusyStateRecoveryTests: XCTestCase {

    // MARK: - Status Decode: All Processing States

    func testStatusThinkingDecodes() {
        let json: [String: Any] = [
            "type": "status",
            "state": "thinking",
            "sessionId": "sess-1"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .status(let state, let sessionId, let toolName) = WSIncoming.decode(from: data) else {
            XCTFail("Expected status"); return
        }
        XCTAssertEqual(state, "thinking")
        XCTAssertEqual(sessionId, "sess-1")
        XCTAssertNil(toolName)
    }

    func testStatusToolRunningDecodes() {
        let json: [String: Any] = [
            "type": "status",
            "state": "tool_running",
            "sessionId": "sess-1",
            "toolName": "Read"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .status(let state, let sessionId, let toolName) = WSIncoming.decode(from: data) else {
            XCTFail("Expected status"); return
        }
        XCTAssertEqual(state, "tool_running")
        XCTAssertEqual(sessionId, "sess-1")
        XCTAssertEqual(toolName, "Read")
    }

    func testStatusToolStartingDecodes() {
        let json: [String: Any] = [
            "type": "status",
            "state": "tool_starting",
            "sessionId": "sess-1"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .status(let state, _, _) = WSIncoming.decode(from: data) else {
            XCTFail("Expected status"); return
        }
        XCTAssertEqual(state, "tool_starting")
    }

    func testStatusIdleDecodes() {
        let json: [String: Any] = [
            "type": "status",
            "state": "idle",
            "sessionId": "sess-1"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .status(let state, let sessionId, _) = WSIncoming.decode(from: data) else {
            XCTFail("Expected status"); return
        }
        XCTAssertEqual(state, "idle")
        XCTAssertEqual(sessionId, "sess-1")
    }

    func testStatusSessionEndedDecodes() {
        let json: [String: Any] = [
            "type": "status",
            "state": "session_ended",
            "sessionId": "sess-1"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .status(let state, _, _) = WSIncoming.decode(from: data) else {
            XCTFail("Expected status"); return
        }
        XCTAssertEqual(state, "session_ended")
    }

    // MARK: - Session List Decode with State Field

    func testSessionListDecodesWithState() {
        let json: [String: Any] = [
            "type": "session_list",
            "sessions": [
                ["sessionId": "s1", "path": "/home/user/project", "state": "idle"],
                ["sessionId": "s2", "path": "/home/user/other", "state": "busy"]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .sessionList(let sessions) = WSIncoming.decode(from: data) else {
            XCTFail("Expected session_list"); return
        }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].sessionId, "s1")
        XCTAssertEqual(sessions[0].state, "idle")
        XCTAssertEqual(sessions[1].sessionId, "s2")
        XCTAssertEqual(sessions[1].state, "busy")
    }

    func testSessionListEmptySessions() {
        let json: [String: Any] = [
            "type": "session_list",
            "sessions": [] as [[String: Any]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .sessionList(let sessions) = WSIncoming.decode(from: data) else {
            XCTFail("Expected session_list"); return
        }
        XCTAssertTrue(sessions.isEmpty)
    }

    func testSessionListSkipsInvalidEntries() {
        let json: [String: Any] = [
            "type": "session_list",
            "sessions": [
                ["sessionId": "s1", "path": "/project", "state": "idle"],
                ["sessionId": "s2", "path": "/other"],  // missing state
                ["sessionId": "s3", "path": "/third", "state": "busy"]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .sessionList(let sessions) = WSIncoming.decode(from: data) else {
            XCTFail("Expected session_list"); return
        }
        XCTAssertEqual(sessions.count, 2, "Entry missing 'state' should be skipped")
        XCTAssertEqual(sessions[0].sessionId, "s1")
        XCTAssertEqual(sessions[1].sessionId, "s3")
    }

    // MARK: - Outgoing Message Encoding

    func testMessageEncoding() throws {
        let data = try WSOutgoing.message(text: "hello", sessionId: "s1").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "message")
        XCTAssertEqual(json["text"] as? String, "hello")
        XCTAssertEqual(json["sessionId"] as? String, "s1")
    }

    func testListSessionsEncoding() throws {
        let data = try WSOutgoing.listSessions.encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "list_sessions")
        XCTAssertEqual(json.count, 1, "list_sessions should only have type")
    }
}
