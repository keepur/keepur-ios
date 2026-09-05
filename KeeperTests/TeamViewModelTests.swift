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

    /// Let the socket's `Task { @MainActor in … }` hops run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
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

    /// Regression: `retryConnect()` clears the banner, then `connectIfPossible()`
    /// re-attempts during backoff *keeping the attempt count*, so a second failure
    /// used to land on `.reconnecting(attempt: 2)` — which the old `handleSocketState`
    /// only banner'd on `attempt == 1` — and the banner never came back.
    func testBannerReturnsAfterFailedManualRetry() async throws {
        // `capability.hives`/`selectedHive` have no test seam (private(set), backed by
        // UserDefaults with a live network refresh), so drive the socket directly —
        // exactly what `connectIfPossible()` does for a valid channel.
        vm.socket.connect(channel: "hive-1")
        let firstTask = try XCTUnwrap(factory.latest)
        firstTask.completeHandshake(error: URLError(.networkConnectionLost))
        await settle()

        XCTAssertEqual(vm.socket.state, .reconnecting(attempt: 1))
        XCTAssertNotNil(vm.disconnectedBanner, "first failure must show the banner")

        // Simulate the manual retry (`retryConnect()`'s effect): clear the banner, then
        // reattempt now instead of waiting out the backoff.
        vm.disconnectedBanner = nil
        vm.socket.connect(channel: "hive-1")
        let secondTask = try XCTUnwrap(factory.latest)
        XCTAssertFalse(secondTask === firstTask, "retry must open a fresh task immediately")
        secondTask.completeHandshake(error: URLError(.networkConnectionLost))
        await settle()

        XCTAssertEqual(vm.socket.state, .reconnecting(attempt: 2))
        XCTAssertNotNil(vm.disconnectedBanner, "banner must return on the second reconnecting transition too")
    }
}
