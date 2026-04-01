import XCTest
@testable import Keepur

final class WorkspaceBrowsingTests: XCTestCase {

    // MARK: - Workspace Model

    func testWorkspaceDisplayName() {
        let ws = Workspace(path: "/Users/dev/my-project")
        XCTAssertEqual(ws.displayName, "my-project")
        XCTAssertEqual(ws.path, "/Users/dev/my-project")
    }

    func testWorkspaceRootPath() {
        let ws = Workspace(path: "/")
        XCTAssertEqual(ws.displayName, "/")
    }

    // MARK: - Browse Encoding

    func testBrowseEncodingWithoutPath() throws {
        let data = try WSOutgoing.browse().encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "browse")
        XCTAssertNil(json["path"])
    }

    func testBrowseEncodingWithPath() throws {
        let data = try WSOutgoing.browse(path: "/home/user").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "browse")
        XCTAssertEqual(json["path"] as? String, "/home/user")
    }

    // MARK: - Browse Result Decoding

    func testBrowseResultDecoding() {
        let json: [String: Any] = [
            "type": "browse_result",
            "path": "/home",
            "entries": [
                ["name": "Documents", "isDirectory": true],
                ["name": "file.txt", "isDirectory": false]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .browseResult(let path, let entries) = WSIncoming.decode(from: data) else {
            XCTFail("Expected browseResult"); return
        }
        XCTAssertEqual(path, "/home")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "Documents")
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries[1].name, "file.txt")
        XCTAssertFalse(entries[1].isDirectory)
    }

    func testBrowseResultEmptyEntries() {
        let json: [String: Any] = [
            "type": "browse_result",
            "path": "/empty",
            "entries": [] as [[String: Any]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .browseResult(let path, let entries) = WSIncoming.decode(from: data) else {
            XCTFail("Expected browseResult"); return
        }
        XCTAssertEqual(path, "/empty")
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - Error Decoding

    func testErrorDecodingWithSessionId() {
        let json: [String: Any] = [
            "type": "error",
            "message": "Session not found",
            "sessionId": "sess-123"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .error(let message, let sessionId) = WSIncoming.decode(from: data) else {
            XCTFail("Expected error"); return
        }
        XCTAssertEqual(message, "Session not found")
        XCTAssertEqual(sessionId, "sess-123")
    }

    func testErrorDecodingWithoutSessionId() {
        let json: [String: Any] = [
            "type": "error",
            "message": "Browse failed"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .error(let message, let sessionId) = WSIncoming.decode(from: data) else {
            XCTFail("Expected error"); return
        }
        XCTAssertEqual(message, "Browse failed")
        XCTAssertNil(sessionId)
    }

    // MARK: - Session Encoding

    func testNewSessionEncoding() throws {
        let data = try WSOutgoing.newSession(path: "/projects/app").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "new_session")
        XCTAssertEqual(json["path"] as? String, "/projects/app")
    }

    func testClearSessionEncoding() throws {
        let data = try WSOutgoing.clearSession(sessionId: "sess-456").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "clear_session")
        XCTAssertEqual(json["sessionId"] as? String, "sess-456")
    }

    func testListSessionsEncoding() throws {
        let data = try WSOutgoing.listSessions.encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "list_sessions")
    }

    // MARK: - Session Decoding

    func testSessionInfoDecoding() {
        let json: [String: Any] = [
            "type": "session_info",
            "sessionId": "sess-789",
            "path": "/workspace/project"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .sessionInfo(let sessionId, let path) = WSIncoming.decode(from: data) else {
            XCTFail("Expected sessionInfo"); return
        }
        XCTAssertEqual(sessionId, "sess-789")
        XCTAssertEqual(path, "/workspace/project")
    }

    func testSessionListDecoding() {
        let json: [String: Any] = [
            "type": "session_list",
            "sessions": [
                ["sessionId": "s1", "path": "/a", "state": "idle"],
                ["sessionId": "s2", "path": "/b", "state": "busy"]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .sessionList(let sessions) = WSIncoming.decode(from: data) else {
            XCTFail("Expected sessionList"); return
        }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].sessionId, "s1")
        XCTAssertEqual(sessions[0].path, "/a")
        XCTAssertEqual(sessions[0].state, "idle")
        XCTAssertEqual(sessions[1].sessionId, "s2")
    }

    func testSessionListEmptySessions() {
        let json: [String: Any] = [
            "type": "session_list",
            "sessions": [] as [[String: Any]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .sessionList(let sessions) = WSIncoming.decode(from: data) else {
            XCTFail("Expected sessionList"); return
        }
        XCTAssertTrue(sessions.isEmpty)
    }

    func testSessionClearedDecoding() {
        let json: [String: Any] = [
            "type": "session_cleared",
            "sessionId": "sess-cleared"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .sessionCleared(let sessionId) = WSIncoming.decode(from: data) else {
            XCTFail("Expected sessionCleared"); return
        }
        XCTAssertEqual(sessionId, "sess-cleared")
    }

    // MARK: - Edge Cases

    func testUnknownTypeReturnsUnknown() {
        let json: [String: Any] = ["type": "unknown_event"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .unknown(let raw) = WSIncoming.decode(from: data) else {
            XCTFail("Expected unknown"); return
        }
        XCTAssertFalse(raw.isEmpty)
    }

    func testMissingTypeReturnsNil() {
        let json: [String: Any] = ["message": "no type"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(WSIncoming.decode(from: data))
    }

    func testInvalidJsonReturnsNil() {
        let data = "not json".data(using: .utf8)!
        XCTAssertNil(WSIncoming.decode(from: data))
    }

    func testSessionInfoMissingPathReturnsNil() {
        let json: [String: Any] = [
            "type": "session_info",
            "sessionId": "sess-789"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(WSIncoming.decode(from: data))
    }

    func testBrowseResultMissingEntriesReturnsNil() {
        let json: [String: Any] = [
            "type": "browse_result",
            "path": "/home"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(WSIncoming.decode(from: data))
    }

    func testSessionListMalformedSessionSkipped() {
        let json: [String: Any] = [
            "type": "session_list",
            "sessions": [
                ["sessionId": "s1", "path": "/a", "state": "idle"],
                ["sessionId": "s2"],
                ["bad": "entry"]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .sessionList(let sessions) = WSIncoming.decode(from: data) else {
            XCTFail("Expected sessionList"); return
        }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sessionId, "s1")
    }

    // MARK: - Message & Approval Encoding

    func testMessageEncoding() throws {
        let data = try WSOutgoing.message(text: "Hello", sessionId: "s1").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "message")
        XCTAssertEqual(json["text"] as? String, "Hello")
        XCTAssertEqual(json["sessionId"] as? String, "s1")
    }

    func testApproveEncoding() throws {
        let data = try WSOutgoing.approve(toolUseId: "tool-1").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "approve")
        XCTAssertEqual(json["toolUseId"] as? String, "tool-1")
    }

    func testDenyEncoding() throws {
        let data = try WSOutgoing.deny(toolUseId: "tool-2").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "deny")
        XCTAssertEqual(json["toolUseId"] as? String, "tool-2")
    }
}
