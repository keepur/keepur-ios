import XCTest
import SwiftUI
@testable import Keepur

final class AgentRowTests: XCTestCase {
    func testRowInstantiatesWithAndWithoutDM() {
        let agent = makeAgent()
        let row1 = AgentRow(agent: agent, dmChannel: nil, isActive: false)
        _ = row1.body

        let channel = TeamChannel(
            id: "c1",
            type: "dm",
            name: "DM",
            members: [agent.id],
            lastMessageText: "hello",
            lastMessageAt: Date()
        )
        let row2 = AgentRow(agent: agent, dmChannel: channel, isActive: true)
        _ = row2.body
    }

    func testStatusTintMapping() {
        for status in ["idle", "processing", "error", "stopped", "unknown"] {
            let agent = makeAgent(status: status)
            let row = AgentRow(agent: agent, dmChannel: nil, isActive: false)
            _ = row.body
        }
    }

    func testEmptyAgentNameRenders() {
        let agent = makeAgent(name: "")
        let row = AgentRow(agent: agent, dmChannel: nil, isActive: false)
        _ = row.body
    }

    private func makeAgent(name: String = "Test", status: String = "idle") -> TeamAgentInfo {
        TeamAgentInfo(
            id: "a1",
            name: name,
            icon: "",
            title: nil,
            model: "claude-sonnet",
            status: status,
            tools: [],
            schedule: [],
            channels: [],
            messagesProcessed: 0,
            lastActivity: nil
        )
    }
}
