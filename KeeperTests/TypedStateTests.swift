import XCTest
@testable import Keepur

@MainActor
final class TypedStateTests: XCTestCase {
    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func testSessionStatusRoundTripsPresentationAndDecode() throws {
        let cases: [(String, SessionStatus, Bool, String?)] = [
            ("idle", .idle, false, nil), ("thinking", .thinking, true, "thinking"),
            ("tool_starting", .toolStarting, true, "starting tool"),
            ("tool_running", .toolRunning, true, "running tool"),
            ("busy", .busy, true, "server busy"),
            ("session_ended", .sessionEnded, false, "session_ended"),
            ("future", .unknown("future"), true, "future"),
            ("", .unknown(""), true, ""), (" Idle ", .unknown(" Idle "), true, " Idle ")
        ]
        for (raw, expected, active, header) in cases {
            let value = SessionStatus(wire: raw)
            XCTAssertEqual(value, expected); XCTAssertEqual(value.wireValue, raw)
            XCTAssertEqual(value.isActive, active); XCTAssertEqual(value.headerText, header)
            guard case .status(let state, let id, let tool) = WSIncoming.decode(from: try data([
                "type": "status", "state": raw, "sessionId": "s", "toolName": "Read"
            ])) else { return XCTFail("status did not decode") }
            XCTAssertEqual(state, expected); XCTAssertEqual(id, "s"); XCTAssertEqual(tool, "Read")
            guard case .sessionList(let rows) = WSIncoming.decode(from: try data([
                "type": "session_list", "sessions": [["sessionId": "s", "path": "/s", "state": raw]]
            ])) else { return XCTFail("list did not decode") }
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.state, expected)
        }
        guard case .status(let state, let id, let tool) = WSIncoming.decode(from: try data([
            "type": "status", "state": "idle"
        ])) else { return XCTFail("optional status fields") }
        XCTAssertEqual(state, .idle); XCTAssertNil(id); XCTAssertNil(tool)
        XCTAssertNil(WSIncoming.decode(from: try data(["type": "status", "state": 7])))
    }

    func testSessionModeDefaultsAndUnknownMembershipInBothFrames() throws {
        let cases: [(Any?, SessionMode)] = [
            (nil, .sessions), (7, .sessions), ("sessions", .sessions), ("concierge", .concierge),
            ("future", .unknown("future")), ("", .unknown(""))
        ]
        for (raw, expected) in cases {
            var info: [String: Any] = ["type": "session_info", "sessionId": "s", "path": "/s"]
            var row: [String: Any] = ["sessionId": "s", "path": "/s", "state": "idle"]
            if let raw { info["mode"] = raw; row["mode"] = raw }
            guard case .sessionInfo(_, _, let mode) = WSIncoming.decode(from: try data(info)),
                  case .sessionList(let rows) = WSIncoming.decode(from: try data([
                    "type": "session_list", "sessions": [row]
                  ])) else { return XCTFail("mode decode") }
            XCTAssertEqual(mode, expected); XCTAssertEqual(rows.first?.mode, expected)
            XCTAssertEqual(SessionMode(wire: expected.wireValue), expected)
        }
        XCTAssertNotEqual(SessionMode(wire: "future"), .sessions)
        XCTAssertNotEqual(SessionMode(wire: "future"), .concierge)
        let outgoing = try JSONSerialization.jsonObject(with: WSOutgoing.newSessionConcierge.encode()) as? [String: String]
        XCTAssertEqual(outgoing, ["type": "new_session", "mode": "concierge"])
    }

    func testTeamDomainsDecodeWithoutDroppingUnknownRows() throws {
        let senders: [(String, SenderType)] = [
            ("person", .person), ("agent", .agent), ("system", .system),
            ("future", .unknown("future")), ("", .unknown(""))
        ]
        for (raw, expected) in senders {
            guard case .history(_, let rows, _, let id) = TeamWSIncoming.decode(from: try data([
                "type": "history", "channelId": "c", "hasMore": false, "id": "request",
                "messages": [["id": "m", "senderId": "other", "senderType": raw,
                              "senderName": "Other", "text": "hello", "createdAt": "2026-09-07T12:00:00.000Z"]]
            ])) else { return XCTFail("history decode") }
            XCTAssertEqual(id, "request"); XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.senderType, expected)
            XCTAssertEqual(rows.first?.senderType.wireValue, raw)
            XCTAssertEqual(SenderType(wire: raw), expected)
        }
        XCTAssertNotEqual(SenderType(wire: "future"), .agent)
        let kinds: [(String, ChannelKind)] = [
            ("channel", .channel), ("dm", .dm), ("future", .unknown("future")), ("", .unknown(""))
        ]
        for (raw, expected) in kinds {
            guard case .channelList(let rows, _) = TeamWSIncoming.decode(from: try data([
                "type": "channel_list", "id": "r", "channels": [["id": "c", "type": raw, "name": "Raw"]]
            ])) else { return XCTFail("channel decode") }
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.type, expected)
            XCTAssertEqual(rows.first?.type.wireValue, raw)
        }
        XCTAssertNotEqual(ChannelKind(wire: "future"), .dm)
        XCTAssertNotEqual(ChannelKind(wire: "future"), .channel)
    }

    func testAgentPresentationAllFieldsAndDecoderDefaults() throws {
        let cases: [(String, AgentStatus, String, String?, Bool, KeepurStatusPill.Tint)] = [
            ("idle", .idle, "Idle", nil, false, .success),
            ("processing", .processing, "Processing", "working", true, .warning),
            ("error", .error, "Error", "error", false, .danger),
            ("stopped", .stopped, "Stopped", "stopped", false, .danger),
            ("customState", .unknown("customState"), "CustomState", "customState", false, .muted),
            ("", .unknown(""), "", "", false, .muted)
        ]
        for (raw, expected, label, header, active, tint) in cases {
            let status = AgentStatus(wire: raw), p = status.presentation
            XCTAssertEqual(status, expected); XCTAssertEqual(status.wireValue, raw)
            XCTAssertEqual(p.label, label); XCTAssertEqual(p.headerText, header)
            XCTAssertEqual(p.isActive, active); XCTAssertEqual(p.tint, tint)
            guard case .agentList(let rows, _) = TeamWSIncoming.decode(from: try data([
                "type": "agent_list", "id": "r", "agents": [["id": "a", "name": "A", "status": raw]]
            ])) else { return XCTFail("agent decode") }
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.status, expected)
        }
        for row: [String: Any] in [["id": "a", "name": "A"], ["id": "a", "name": "A", "status": 7]] {
            guard case .agentList(let rows, _) = TeamWSIncoming.decode(from: try data([
                "type": "agent_list", "id": "r", "agents": [row]
            ])) else { return XCTFail("agent default") }
            XCTAssertEqual(rows.first?.status, .idle)
        }
        let absent: AgentStatus? = nil
        XCTAssertNil(absent?.presentation.headerText)
        XCTAssertFalse(absent?.presentation.isActive ?? false)
    }
}
