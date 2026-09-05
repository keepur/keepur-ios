import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class TeamViewModelTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var credentials: FakeCredentialStore!
    private var factory: FakeWebSocketTaskFactory!
    private var capability: CapabilityManager!   // held here: TeamViewModel keeps it weak
    private var vm: TeamViewModel!

    override func setUp() async throws {
        let schema = Schema([TeamChannel.self, TeamMessage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        credentials = FakeCredentialStore(deviceId: "device-old")
        factory = FakeWebSocketTaskFactory()
        capability = CapabilityManager()
        let factory = self.factory!
        let socket = BeekeeperSocket(
            config: .standard,
            credentials: credentials,
            endpoint: { URL(string: "wss://unit.test")! },
            taskFactory: { factory.make(url: $0) }   // closure literal, not `factory.make`
        )
        vm = TeamViewModel(socket: socket, credentials: credentials)
        vm.configure(context: context, capabilityManager: capability)
        vm.activeChannelId = "channel-1"
    }

    override func tearDown() async throws {
        vm = nil
        capability = nil
        context = nil
        container = nil
    }

    private func senderIdsByText() throws -> [String: String] {
        let rows = try context.fetch(FetchDescriptor<TeamMessage>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.text, $0.senderId) })
    }

    func testDeviceIdFollowsCredentialStore() throws {
        vm.sendMessage(text: "first")
        credentials.deviceId = "device-new"     // what a re-pair does
        vm.sendMessage(text: "second")

        let senders = try senderIdsByText()
        XCTAssertEqual(senders, ["first": "device-old", "second": "device-new"],
                       "sender id must be read at send time, not captured in configure")
        let rows = try context.fetch(FetchDescriptor<TeamMessage>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy(\.pending), "socket never connected, so nothing was acked")
    }
}
