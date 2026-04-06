import XCTest
@testable import Keepur

final class TeamWSMessageTests: XCTestCase {

    // MARK: - Outgoing Encoding

    func testTeamMessageEncoding() throws {
        let (data, id) = try TeamWSOutgoing.teamMessage(channelId: "general", text: "Hello", threadId: nil).encodeWithId()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "message")
        XCTAssertEqual(json["channelId"] as? String, "general")
        XCTAssertEqual(json["text"] as? String, "Hello")
        XCTAssertEqual(json["id"] as? String, id)
        XCTAssertNil(json["threadId"])
    }

    func testTeamMessageWithThreadEncoding() throws {
        let data = try TeamWSOutgoing.teamMessage(channelId: "ch1", text: "Reply", threadId: "thread-abc").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "message")
        XCTAssertEqual(json["threadId"] as? String, "thread-abc")
    }

    func testChannelListEncoding() throws {
        let data = try TeamWSOutgoing.channelList.encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "channel_list")
        XCTAssertNotNil(json["id"] as? String) // Should always have a request ID
    }

    func testHistoryEncoding() throws {
        let data = try TeamWSOutgoing.history(channelId: "general", before: "abc123", limit: 50).encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "history")
        XCTAssertEqual(json["channelId"] as? String, "general")
        XCTAssertEqual(json["before"] as? String, "abc123")
        XCTAssertEqual(json["limit"] as? Int, 50)
    }

    func testHistoryEncodingWithoutOptionals() throws {
        let data = try TeamWSOutgoing.history(channelId: "general", before: nil, limit: nil).encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "history")
        XCTAssertNil(json["before"])
        XCTAssertNil(json["limit"])
    }

    func testJoinEncoding() throws {
        let data = try TeamWSOutgoing.join(channelId: "new-channel").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "join")
        XCTAssertEqual(json["channelId"] as? String, "new-channel")
    }

    func testCommandEncoding() throws {
        let data = try TeamWSOutgoing.command(channelId: "general", name: "new", args: ["dev", "agent1"]).encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "command")
        XCTAssertEqual(json["name"] as? String, "new")
        XCTAssertEqual(json["args"] as? [String], ["dev", "agent1"])
    }

    func testPingEncoding() throws {
        let data = try TeamWSOutgoing.ping.encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "ping")
    }

    func testEncodeAndEncodeWithIdProduceSameStructure() throws {
        let outgoing = TeamWSOutgoing.teamMessage(channelId: "ch1", text: "test", threadId: nil)
        let plainData = try outgoing.encode()
        let plainJson = try JSONSerialization.jsonObject(with: plainData) as! [String: Any]
        // encode() delegates to encodeWithId(), so both should produce valid JSON with type + id
        XCTAssertEqual(plainJson["type"] as? String, "message")
        XCTAssertNotNil(plainJson["id"] as? String)
    }

    // MARK: - Incoming Decoding: teamMessage

    func testDecodeTeamMessageWithChannelId() {
        let json: [String: Any] = [
            "type": "message",
            "text": "Hello from agent",
            "channelId": "general",
            "agentId": "production-support",
            "agentName": "production-support"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .teamMessage(let text, let channelId, let agentId, let agentName, let replyTo) = TeamWSIncoming.decode(from: data) else {
            XCTFail("Expected teamMessage"); return
        }
        XCTAssertEqual(text, "Hello from agent")
        XCTAssertEqual(channelId, "general")
        XCTAssertEqual(agentId, "production-support")
        XCTAssertEqual(agentName, "production-support")
        XCTAssertNil(replyTo)
    }

    // MARK: - Incoming Decoding: systemMessage

    func testDecodeSystemMessageWithoutChannelId() {
        let json: [String: Any] = [
            "type": "message",
            "text": "Command result",
            "agentId": "system",
            "agentName": "system",
            "replyTo": "req-uuid-123"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .systemMessage(let text, let agentId, let agentName, let replyTo) = TeamWSIncoming.decode(from: data) else {
            XCTFail("Expected systemMessage"); return
        }
        XCTAssertEqual(text, "Command result")
        XCTAssertEqual(agentId, "system")
        XCTAssertEqual(agentName, "system")
        XCTAssertEqual(replyTo, "req-uuid-123")
    }

    // MARK: - Incoming Decoding: channelList

    func testDecodeChannelList() {
        let json: [String: Any] = [
            "type": "channel_list",
            "id": "req-1",
            "channels": [
                ["id": "general", "type": "channel", "name": "general", "members": ["agent1", "device1"]],
                ["id": "dm:a:b", "type": "dm", "name": "Agent B", "members": ["a", "b"]]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .channelList(let channels, let id) = TeamWSIncoming.decode(from: data) else {
            XCTFail("Expected channelList"); return
        }
        XCTAssertEqual(id, "req-1")
        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels[0].id, "general")
        XCTAssertEqual(channels[0].type, "channel")
        XCTAssertEqual(channels[1].type, "dm")
        XCTAssertEqual(channels[0].members, ["agent1", "device1"])
    }

    func testDecodeChannelListWithMissingMembers() {
        let json: [String: Any] = [
            "type": "channel_list",
            "id": "req-2",
            "channels": [
                ["id": "general", "type": "channel", "name": "general"]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .channelList(let channels, _) = TeamWSIncoming.decode(from: data) else {
            XCTFail("Expected channelList"); return
        }
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].members, [])  // Defaults to empty
    }

    // MARK: - Incoming Decoding: history

    func testDecodeHistory() {
        let json: [String: Any] = [
            "type": "history",
            "channelId": "general",
            "hasMore": true,
            "id": "req-3",
            "messages": [
                [
                    "id": "mongo-id-1",
                    "senderId": "agent1",
                    "senderType": "agent",
                    "senderName": "Agent One",
                    "text": "Hello",
                    "createdAt": "2026-04-06T10:00:00.000Z"
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .history(let channelId, let messages, let hasMore, let id) = TeamWSIncoming.decode(from: data) else {
            XCTFail("Expected history"); return
        }
        XCTAssertEqual(channelId, "general")
        XCTAssertEqual(id, "req-3")
        XCTAssertTrue(hasMore)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].id, "mongo-id-1")
        XCTAssertEqual(messages[0].senderId, "agent1")
        XCTAssertEqual(messages[0].text, "Hello")
    }

    // MARK: - Incoming Decoding: channelEvent

    func testDecodeChannelEventWithDetail() {
        let json: [String: Any] = [
            "type": "channel_event",
            "channelId": "general",
            "event": "joined",
            "id": "req-4",
            "detail": ["memberId": "device-123"]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .channelEvent(let channelId, let event, let memberId, let id) = TeamWSIncoming.decode(from: data) else {
            XCTFail("Expected channelEvent"); return
        }
        XCTAssertEqual(channelId, "general")
        XCTAssertEqual(event, "joined")
        XCTAssertEqual(memberId, "device-123")
        XCTAssertEqual(id, "req-4")
    }

    func testDecodeChannelEventWithoutDetail() {
        let json: [String: Any] = [
            "type": "channel_event",
            "channelId": "general",
            "event": "archived",
            "id": "req-5"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .channelEvent(_, _, let memberId, _) = TeamWSIncoming.decode(from: data) else {
            XCTFail("Expected channelEvent"); return
        }
        XCTAssertNil(memberId)
    }

    func testDecodeChannelEventWithEmptyDetail() {
        // Server sends detail: {} for archived events (no memberId key)
        let json: [String: Any] = [
            "type": "channel_event",
            "channelId": "general",
            "event": "archived",
            "detail": [String: Any](),
            "id": "req-6"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .channelEvent(_, _, let memberId, _) = TeamWSIncoming.decode(from: data) else {
            XCTFail("Expected channelEvent"); return
        }
        XCTAssertNil(memberId)
    }

    // MARK: - Incoming Decoding: ack, typing, error, pong

    func testDecodeAck() {
        let json: [String: Any] = ["type": "ack", "id": "req-uuid"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .ack(let id) = TeamWSIncoming.decode(from: data) else {
            XCTFail("Expected ack"); return
        }
        XCTAssertEqual(id, "req-uuid")
    }

    func testDecodeTyping() {
        let json: [String: Any] = ["type": "typing", "agentId": "agent1"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .typing(let agentId) = TeamWSIncoming.decode(from: data) else {
            XCTFail("Expected typing"); return
        }
        XCTAssertEqual(agentId, "agent1")
    }

    func testDecodeError() {
        let json: [String: Any] = ["type": "error", "message": "Something went wrong"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .error(let message) = TeamWSIncoming.decode(from: data) else {
            XCTFail("Expected error"); return
        }
        XCTAssertEqual(message, "Something went wrong")
    }

    func testDecodeErrorWithoutMessage() {
        let json: [String: Any] = ["type": "error"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .error(let message) = TeamWSIncoming.decode(from: data) else {
            XCTFail("Expected error"); return
        }
        XCTAssertEqual(message, "Unknown error")
    }

    func testDecodePong() {
        let json: [String: Any] = ["type": "pong"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .pong = TeamWSIncoming.decode(from: data) else {
            XCTFail("Expected pong"); return
        }
    }

    // MARK: - Edge Cases

    func testDecodeUnknownTypeReturnsNil() {
        let json: [String: Any] = ["type": "something_new", "data": "hello"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(TeamWSIncoming.decode(from: data))
    }

    func testDecodeInvalidJsonReturnsNil() {
        let data = "not json".data(using: .utf8)!
        XCTAssertNil(TeamWSIncoming.decode(from: data))
    }

    func testDecodeMessageMissingRequiredFieldsReturnsNil() {
        let json: [String: Any] = [
            "type": "message",
            "text": "Hello"
            // Missing agentId and agentName
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(TeamWSIncoming.decode(from: data))
    }
}
