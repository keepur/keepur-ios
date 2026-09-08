import XCTest
@testable import Keepur

final class ChatHeaderMappingTests: XCTestCase {
    func testChatViewStatusMapping() {
        XCTAssertEqual(SessionStatus(wire: "idle").headerText, nil)
        XCTAssertEqual(SessionStatus(wire: "idle").isActive, false)

        XCTAssertEqual(SessionStatus(wire: "thinking").headerText, "thinking")
        XCTAssertTrue(SessionStatus(wire: "thinking").isActive)

        XCTAssertEqual(SessionStatus(wire: "tool_running").headerText, "running tool")
        XCTAssertTrue(SessionStatus(wire: "tool_running").isActive)

        XCTAssertEqual(SessionStatus(wire: "tool_starting").headerText, "starting tool")
        XCTAssertTrue(SessionStatus(wire: "tool_starting").isActive)

        XCTAssertEqual(SessionStatus(wire: "busy").headerText, "server busy")
        XCTAssertTrue(SessionStatus(wire: "busy").isActive)

        XCTAssertEqual(SessionStatus(wire: "custom").headerText, "custom")
        XCTAssertTrue(SessionStatus(wire: "custom").isActive)
    }

    func testTeamChatViewAgentStatusMapping() {
        let absent: AgentStatus? = nil
        XCTAssertNil(absent?.presentation.headerText)
        XCTAssertFalse(absent?.presentation.isActive ?? false)

        XCTAssertNil(AgentStatus(wire: "idle").presentation.headerText)
        XCTAssertFalse(AgentStatus(wire: "idle").presentation.isActive)

        XCTAssertEqual(AgentStatus(wire: "processing").presentation.headerText, "working")
        XCTAssertTrue(AgentStatus(wire: "processing").presentation.isActive)

        XCTAssertEqual(AgentStatus(wire: "error").presentation.headerText, "error")
        XCTAssertFalse(AgentStatus(wire: "error").presentation.isActive)

        XCTAssertEqual(AgentStatus(wire: "stopped").presentation.headerText, "stopped")
        XCTAssertFalse(AgentStatus(wire: "stopped").presentation.isActive)

        XCTAssertEqual(AgentStatus(wire: "custom").presentation.headerText, "custom")
        XCTAssertFalse(AgentStatus(wire: "custom").presentation.isActive)
    }
}
