import Testing
import Foundation
@testable import Keepur

// MARK: - Workspace Model

@Suite("Workspace Model")
struct WorkspaceModelTests {

    @Test("displayName returns last path component")
    func displayName() {
        let ws = Workspace(path: "/Users/may/projects/hive")
        #expect(ws.displayName == "hive")
    }

    @Test("displayName for single component path")
    func displayNameSingleComponent() {
        let ws = Workspace(path: "/home")
        #expect(ws.displayName == "home")
    }

    @Test("displayName for root path")
    func displayNameRoot() {
        let ws = Workspace(path: "/")
        #expect(ws.displayName == "/")
    }

    @Test("init sets lastUsed to now")
    func initSetsLastUsed() {
        let before = Date.now
        let ws = Workspace(path: "/tmp")
        let after = Date.now
        #expect(ws.lastUsed >= before)
        #expect(ws.lastUsed <= after)
    }
}

// MARK: - WSOutgoing Browse Encoding

@Suite("WSOutgoing Browse Encoding")
struct BrowseEncodingTests {

    @Test("browse without path encodes type only")
    func browseNoPath() throws {
        let data = try WSOutgoing.browse().encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "browse")
        #expect(json["path"] == nil)
    }

    @Test("browse with path encodes type and path")
    func browseWithPath() throws {
        let data = try WSOutgoing.browse(path: "/Users/may/projects").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "browse")
        #expect(json["path"] as? String == "/Users/may/projects")
    }
}

// MARK: - WSIncoming Browse Result Decoding

@Suite("WSIncoming Browse Result Decoding")
struct BrowseResultDecodingTests {

    private func jsonData(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    @Test("decodes browse_result with entries")
    func decodeBrowseResult() {
        let data = jsonData([
            "type": "browse_result",
            "path": "/Users/may/projects",
            "entries": [
                ["name": "hive", "isDirectory": true],
                ["name": "README.md", "isDirectory": false]
            ]
        ])
        guard case .browseResult(let path, let entries) = WSIncoming.decode(from: data) else {
            Issue.record("Expected browseResult")
            return
        }
        #expect(path == "/Users/may/projects")
        #expect(entries.count == 2)
        #expect(entries[0].name == "hive")
        #expect(entries[0].isDirectory == true)
        #expect(entries[1].name == "README.md")
        #expect(entries[1].isDirectory == false)
    }

    @Test("decodes browse_result with empty entries")
    func decodeBrowseResultEmpty() {
        let data = jsonData([
            "type": "browse_result",
            "path": "/Users/may/empty",
            "entries": [] as [[String: Any]]
        ])
        guard case .browseResult(let path, let entries) = WSIncoming.decode(from: data) else {
            Issue.record("Expected browseResult")
            return
        }
        #expect(path == "/Users/may/empty")
        #expect(entries.isEmpty)
    }

    @Test("returns nil for browse_result missing path")
    func decodeBrowseResultMissingPath() {
        let data = jsonData([
            "type": "browse_result",
            "entries": [["name": "x", "isDirectory": true]]
        ])
        #expect(WSIncoming.decode(from: data) == nil)
    }

    @Test("returns nil for browse_result missing entries")
    func decodeBrowseResultMissingEntries() {
        let data = jsonData([
            "type": "browse_result",
            "path": "/Users/may"
        ])
        #expect(WSIncoming.decode(from: data) == nil)
    }

    @Test("skips malformed entries in browse_result")
    func decodeBrowseResultMalformedEntries() {
        let data = jsonData([
            "type": "browse_result",
            "path": "/Users/may",
            "entries": [
                ["name": "good", "isDirectory": true],
                ["name": "bad"],  // missing isDirectory
                ["isDirectory": false]  // missing name
            ]
        ])
        guard case .browseResult(_, let entries) = WSIncoming.decode(from: data) else {
            Issue.record("Expected browseResult")
            return
        }
        #expect(entries.count == 1)
        #expect(entries[0].name == "good")
    }
}

// MARK: - WSIncoming Error Decoding (browse errors)

@Suite("WSIncoming Error Decoding")
struct ErrorDecodingTests {

    private func jsonData(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    @Test("decodes error with nil sessionId (browse error)")
    func decodeErrorNilSession() {
        let data = jsonData([
            "type": "error",
            "message": "Path must be a directory under home"
        ])
        guard case .error(let message, let sessionId) = WSIncoming.decode(from: data) else {
            Issue.record("Expected error")
            return
        }
        #expect(message == "Path must be a directory under home")
        #expect(sessionId == nil)
    }

    @Test("decodes error with sessionId")
    func decodeErrorWithSession() {
        let data = jsonData([
            "type": "error",
            "message": "Something went wrong",
            "sessionId": "abc-123"
        ])
        guard case .error(let message, let sessionId) = WSIncoming.decode(from: data) else {
            Issue.record("Expected error")
            return
        }
        #expect(message == "Something went wrong")
        #expect(sessionId == "abc-123")
    }
}

// MARK: - WSIncoming General Decoding Edge Cases

@Suite("WSIncoming General Decoding")
struct GeneralDecodingTests {

    @Test("returns nil for unknown type")
    func decodeUnknownType() {
        let data = try! JSONSerialization.data(withJSONObject: ["type": "unknown_msg"])
        #expect(WSIncoming.decode(from: data) == nil)
    }

    @Test("returns nil for invalid JSON")
    func decodeInvalidJSON() {
        let data = "not json".data(using: .utf8)!
        #expect(WSIncoming.decode(from: data) == nil)
    }

    @Test("returns nil for JSON without type")
    func decodeMissingType() {
        let data = try! JSONSerialization.data(withJSONObject: ["foo": "bar"])
        #expect(WSIncoming.decode(from: data) == nil)
    }
}
