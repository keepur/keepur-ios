import XCTest
@testable import Keepur

final class ChatHeaderMappingTests: XCTestCase {
    func testChatViewStatusMapping() {
        XCTAssertEqual(ChatView.mapSessionStatus("idle").text, nil)
        XCTAssertEqual(ChatView.mapSessionStatus("idle").isActive, false)

        XCTAssertEqual(ChatView.mapSessionStatus("thinking").text, "thinking")
        XCTAssertTrue(ChatView.mapSessionStatus("thinking").isActive)

        XCTAssertEqual(ChatView.mapSessionStatus("tool_running").text, "running tool")
        XCTAssertTrue(ChatView.mapSessionStatus("tool_running").isActive)

        XCTAssertEqual(ChatView.mapSessionStatus("tool_starting").text, "starting tool")
        XCTAssertTrue(ChatView.mapSessionStatus("tool_starting").isActive)

        XCTAssertEqual(ChatView.mapSessionStatus("busy").text, "server busy")
        XCTAssertTrue(ChatView.mapSessionStatus("busy").isActive)

        XCTAssertEqual(ChatView.mapSessionStatus("custom").text, "custom")
        XCTAssertFalse(ChatView.mapSessionStatus("custom").isActive)
    }

    func testTeamChatViewAgentStatusMapping() {
        XCTAssertNil(TeamChatView.mapAgentStatus(nil).text)
        XCTAssertFalse(TeamChatView.mapAgentStatus(nil).isActive)

        XCTAssertNil(TeamChatView.mapAgentStatus("idle").text)
        XCTAssertFalse(TeamChatView.mapAgentStatus("idle").isActive)

        XCTAssertEqual(TeamChatView.mapAgentStatus("processing").text, "working")
        XCTAssertTrue(TeamChatView.mapAgentStatus("processing").isActive)

        XCTAssertEqual(TeamChatView.mapAgentStatus("error").text, "error")
        XCTAssertFalse(TeamChatView.mapAgentStatus("error").isActive)

        XCTAssertEqual(TeamChatView.mapAgentStatus("stopped").text, "stopped")
        XCTAssertFalse(TeamChatView.mapAgentStatus("stopped").isActive)

        XCTAssertEqual(TeamChatView.mapAgentStatus("custom").text, "custom")
        XCTAssertFalse(TeamChatView.mapAgentStatus("custom").isActive)
    }
}
