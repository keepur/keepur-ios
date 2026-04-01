import XCTest
@testable import Keepur

final class ChatResilienceTests: XCTestCase {

    // MARK: - Cancel Encoding

    func testCancelEncoding() throws {
        let data = try WSOutgoing.cancel(sessionId: "sess-abc").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "cancel")
        XCTAssertEqual(json["sessionId"] as? String, "sess-abc")
    }

    func testCancelEncodingHasNoExtraKeys() throws {
        let data = try WSOutgoing.cancel(sessionId: "s1").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json.count, 2, "cancel should only have type and sessionId")
    }

    // MARK: - Unknown Decoding

    func testUnknownTypeWithTextField() {
        let json: [String: Any] = [
            "type": "new_feature",
            "text": "Hello from the future"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .unknown(let raw) = WSIncoming.decode(from: data) else {
            XCTFail("Expected unknown"); return
        }
        XCTAssertEqual(raw, "Hello from the future")
    }

    func testUnknownTypeWithMessageField() {
        let json: [String: Any] = [
            "type": "new_feature",
            "message": "Use the message field"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .unknown(let raw) = WSIncoming.decode(from: data) else {
            XCTFail("Expected unknown"); return
        }
        XCTAssertEqual(raw, "Use the message field")
    }

    func testUnknownTypeWithContentField() {
        let json: [String: Any] = [
            "type": "new_feature",
            "content": "Content fallback"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .unknown(let raw) = WSIncoming.decode(from: data) else {
            XCTFail("Expected unknown"); return
        }
        XCTAssertEqual(raw, "Content fallback")
    }

    func testUnknownTypeTextFieldTakesPriority() {
        let json: [String: Any] = [
            "type": "new_feature",
            "text": "primary",
            "message": "secondary",
            "content": "tertiary"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .unknown(let raw) = WSIncoming.decode(from: data) else {
            XCTFail("Expected unknown"); return
        }
        XCTAssertEqual(raw, "primary", "text field should take priority over message and content")
    }

    func testUnknownTypeNoTextFieldsFallsBackToRawJson() {
        let json: [String: Any] = [
            "type": "mystery",
            "data": 42
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .unknown(let raw) = WSIncoming.decode(from: data) else {
            XCTFail("Expected unknown"); return
        }
        // Falls back to raw JSON string — should contain the type and data
        XCTAssertFalse(raw.isEmpty)
        XCTAssertTrue(raw.contains("mystery"))
    }

    func testUnknownTypeEmptyObject() {
        let json: [String: Any] = ["type": "empty_event"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .unknown(let raw) = WSIncoming.decode(from: data) else {
            XCTFail("Expected unknown"); return
        }
        XCTAssertFalse(raw.isEmpty)
    }

    // MARK: - Missing Type Still Returns Nil

    func testMissingTypeStillReturnsNil() {
        let json: [String: Any] = ["text": "no type field"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(WSIncoming.decode(from: data))
    }

    func testInvalidJsonStillReturnsNil() {
        let data = "not json at all".data(using: .utf8)!
        XCTAssertNil(WSIncoming.decode(from: data))
    }

    // MARK: - Status Busy Decoding

    func testStatusBusyDecoding() {
        let json: [String: Any] = [
            "type": "status",
            "state": "busy",
            "sessionId": "sess-1"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .status(let state, let sessionId) = WSIncoming.decode(from: data) else {
            XCTFail("Expected status"); return
        }
        XCTAssertEqual(state, "busy")
        XCTAssertEqual(sessionId, "sess-1")
    }

    func testStatusBusyWithoutSessionId() {
        let json: [String: Any] = [
            "type": "status",
            "state": "busy"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .status(let state, let sessionId) = WSIncoming.decode(from: data) else {
            XCTFail("Expected status"); return
        }
        XCTAssertEqual(state, "busy")
        XCTAssertNil(sessionId)
    }

    // MARK: - Known Types Still Decode Correctly

    func testKnownMessageStillDecodes() {
        let json: [String: Any] = [
            "type": "message",
            "text": "Hello",
            "sessionId": "s1",
            "final": true
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .message(let text, let sessionId, let final) = WSIncoming.decode(from: data) else {
            XCTFail("Expected message"); return
        }
        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(sessionId, "s1")
        XCTAssertTrue(final)
    }

    func testKnownPongStillDecodes() {
        let json: [String: Any] = ["type": "pong"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .pong = WSIncoming.decode(from: data) else {
            XCTFail("Expected pong"); return
        }
    }
}
