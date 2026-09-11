import XCTest
@testable import Keepur

final class AgentDetailSheetTests: XCTestCase {

    func testStatusTintMapping() {
        XCTAssertEqual(AgentStatus(wire: "idle").presentation.tint,       .success)
        XCTAssertEqual(AgentStatus(wire: "processing").presentation.tint, .warning)
        XCTAssertEqual(AgentStatus(wire: "error").presentation.tint,      .danger)
        XCTAssertEqual(AgentStatus(wire: "stopped").presentation.tint,    .danger)
        XCTAssertEqual(AgentStatus(wire: "unknown").presentation.tint,    .muted)
        XCTAssertEqual(AgentStatus(wire: "").presentation.tint,           .muted)
    }

    func testStatusDisplayTitleCases() {
        XCTAssertEqual(AgentStatus(wire: "idle").presentation.label,       "Idle")
        XCTAssertEqual(AgentStatus(wire: "processing").presentation.label, "Processing")
        XCTAssertEqual(AgentStatus(wire: "error").presentation.label,      "Error")
        XCTAssertEqual(AgentStatus(wire: "").presentation.label,           "")
    }

    func testLastActiveDisplayHandlesNilAndMalformed() {
        XCTAssertEqual(AgentDetailSheet.lastActiveDisplay(from: nil),       "Never")
        XCTAssertEqual(AgentDetailSheet.lastActiveDisplay(from: "garbage"), "Never")
        XCTAssertEqual(AgentDetailSheet.lastActiveDisplay(from: ""),        "Never")
    }

    func testLastActiveDisplayParsesValidISO() {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let recent = iso.string(from: Date().addingTimeInterval(-120))
        let result = AgentDetailSheet.lastActiveDisplay(from: recent)
        XCTAssertFalse(result.isEmpty)
        XCTAssertNotEqual(result, "Never")
    }

    func testLastActiveDisplayParsesISOWithoutFractionalSeconds() {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let recent = iso.string(from: Date().addingTimeInterval(-60))
        let result = AgentDetailSheet.lastActiveDisplay(from: recent)
        XCTAssertNotEqual(result, "Never")
    }

    func testHeaderAvatarContentPrefersIconThenLetterThenQuestion() {
        let withIcon = makeAgent(icon: "🤖", name: "Coder")
        if case .emoji(let raw) = AgentDetailSheet.headerAvatarContent(for: withIcon) {
            XCTAssertEqual(raw, "🤖")
        } else {
            XCTFail("expected emoji content")
        }

        let withName = makeAgent(icon: "", name: "Coder")
        if case .letter(let raw) = AgentDetailSheet.headerAvatarContent(for: withName) {
            XCTAssertEqual(raw, "Coder")
        } else {
            XCTFail("expected letter content")
        }

        let bare = makeAgent(icon: "", name: "")
        if case .letter(let raw) = AgentDetailSheet.headerAvatarContent(for: bare) {
            XCTAssertEqual(raw, "?")
        } else {
            XCTFail("expected letter fallback")
        }
    }

    func testModelDisplayEmDashWhenEmpty() {
        XCTAssertEqual(AgentDetailSheet.modelDisplay(for: makeAgent(model: "")),                "—")
        XCTAssertEqual(AgentDetailSheet.modelDisplay(for: makeAgent(model: "claude-sonnet-4")), "claude-sonnet-4")
    }

    private func makeAgent(
        icon: String = "🤖",
        name: String = "Test Agent",
        model: String = "claude-sonnet-4",
        status: AgentStatus = .idle
    ) -> TeamAgentInfo {
        TeamAgentInfo(
            id: "a1",
            name: name,
            icon: icon,
            title: nil,
            model: model,
            status: status,
            tools: [],
            schedule: [],
            channels: [],
            messagesProcessed: 0,
            lastActivity: nil
        )
    }
}
