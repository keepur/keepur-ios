import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class TeamSortedAgentsTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: TeamViewModel!
    private var capability: CapabilityManager!

    override func setUp() async throws {
        let schema = Schema([TeamChannel.self, TeamMessage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        capability = CapabilityManager()
        vm = TeamViewModel()
        vm.configure(context: context, capabilityManager: capability)
    }

    override func tearDown() async throws {
        vm = nil
        context = nil
        container = nil
        capability = nil
    }

    // MARK: - Fixtures

    private func makeAgent(id: String, name: String, status: String = "idle") -> TeamAgentInfo {
        TeamAgentInfo(
            id: id,
            name: name,
            icon: "",
            title: nil,
            model: "claude-sonnet-4-5",
            status: status,
            tools: [],
            schedule: [],
            channels: [],
            messagesProcessed: 0,
            lastActivity: nil
        )
    }

    private func insertDM(id: String, memberIds: [String], lastAt: Date?, preview: String? = "hi") {
        let ch = TeamChannel(
            id: id,
            type: "dm",
            name: "dm-\(id)",
            members: memberIds,
            lastMessageText: preview,
            lastMessageAt: lastAt
        )
        context.insert(ch)
        try? context.save()
        vm.channels.append(ch)
    }

    // MARK: - Tests

    /// Agents with more-recent DM activity sort above agents with older DM activity.
    func testSortByLastMessageDescending() {
        let a1 = makeAgent(id: "a1", name: "Alpha")
        let a2 = makeAgent(id: "a2", name: "Bravo")
        vm.agents = [a1, a2]

        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        insertDM(id: "dm1", memberIds: ["a1"], lastAt: older)
        insertDM(id: "dm2", memberIds: ["a2"], lastAt: newer)

        vm.recomputeSortedAgents()

        XCTAssertEqual(vm.sortedAgents.map(\.agent.id), ["a2", "a1"])
    }

    /// Agents without a DM (nil lastMessageAt) sort at the bottom.
    func testAgentsWithoutDMSortLast() {
        let a1 = makeAgent(id: "a1", name: "Alpha")
        let a2 = makeAgent(id: "a2", name: "Bravo")
        let a3 = makeAgent(id: "a3", name: "Charlie")
        vm.agents = [a1, a2, a3]

        insertDM(id: "dm1", memberIds: ["a1"], lastAt: Date(timeIntervalSince1970: 1_000_000))

        vm.recomputeSortedAgents()

        XCTAssertEqual(vm.sortedAgents.first?.agent.id, "a1")
        let tail = vm.sortedAgents.dropFirst().map(\.agent.id)
        XCTAssertEqual(Set(tail), Set(["a2", "a3"]))
    }

    /// Alphabetical tiebreaker when neither agent has a DM.
    func testAlphabeticalTiebreakerForNoDM() {
        let a1 = makeAgent(id: "a1", name: "Charlie")
        let a2 = makeAgent(id: "a2", name: "Alpha")
        let a3 = makeAgent(id: "a3", name: "Bravo")
        vm.agents = [a1, a2, a3]

        vm.recomputeSortedAgents()

        XCTAssertEqual(vm.sortedAgents.map(\.agent.name), ["Alpha", "Bravo", "Charlie"])
    }

    /// DM channel is matched to the correct agent via members.contains.
    func testDMChannelPairedByMembers() {
        let a1 = makeAgent(id: "agent-1", name: "Alpha")
        let a2 = makeAgent(id: "agent-2", name: "Bravo")
        vm.agents = [a1, a2]

        insertDM(id: "dm1", memberIds: ["agent-2"], lastAt: Date())

        vm.recomputeSortedAgents()

        let alphaEntry = vm.sortedAgents.first { $0.agent.id == "agent-1" }
        let bravoEntry = vm.sortedAgents.first { $0.agent.id == "agent-2" }
        XCTAssertNil(alphaEntry?.dmChannel)
        XCTAssertEqual(bravoEntry?.dmChannel?.id, "dm1")
    }

    /// Non-DM channels (type != "dm") are ignored when pairing.
    func testNonDMChannelsIgnored() {
        let a1 = makeAgent(id: "a1", name: "Alpha")
        vm.agents = [a1]

        let ch = TeamChannel(
            id: "group1",
            type: "channel",
            name: "general",
            members: ["a1"],
            lastMessageText: "hi",
            lastMessageAt: Date()
        )
        context.insert(ch)
        try? context.save()
        vm.channels.append(ch)

        vm.recomputeSortedAgents()

        XCTAssertNil(vm.sortedAgents.first?.dmChannel)
    }

    /// All agents appear in the sorted list regardless of DM presence.
    func testAllAgentsAlwaysVisible() {
        let agents = (0..<5).map { makeAgent(id: "a\($0)", name: "Agent \($0)") }
        vm.agents = agents

        vm.recomputeSortedAgents()

        XCTAssertEqual(vm.sortedAgents.count, 5)
    }
}
