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
        UserDefaults.standard.removeObject(forKey: "selectedHive")
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
        UserDefaults.standard.removeObject(forKey: "selectedHive")
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
        // The seam is `_setHivesForTesting` (CapabilityManager.swift ~82): it sets
        // `hives` and, via `reconcileSelectedHive`, `selectedHive`. Seeding a single
        // hive here is required, not incidental — `connectIfPossible()` needs a valid
        // `selectedHive` to connect at all, and on the first `.reconnecting` transition
        // `refreshCapabilitiesAfterConnectionLost()` fires a real `manager.refresh()`
        // that fails in tests (no token, so `APIManager.fetchCapabilities`/`fetchMe`
        // throw immediately). A failed refresh leaves `hives`/`selectedHive` untouched,
        // so with a hive already seeded, `performRefresh`'s `catch` branch takes the
        // harmless "hive still exists" path instead of tearing the banner/socket down
        // via the hive-vanished branch.
        capability._setHivesForTesting(["hive-1"])
        XCTAssertEqual(capability.selectedHive, "hive-1")

        vm.connectIfPossible()
        let firstTask = try XCTUnwrap(factory.latest)
        XCTAssertTrue(firstTask.url.absoluteString.hasSuffix("&channel=hive-1"))
        firstTask.completeHandshake(error: URLError(.networkConnectionLost))
        await settle()

        XCTAssertEqual(vm.socket.state, .reconnecting(attempt: 1))
        let firstBanner = try XCTUnwrap(vm.disconnectedBanner, "first failure must show the banner")
        XCTAssertTrue(firstBanner.contains("hive-1"))

        // `retryConnect()` clears the banner, then reattempts immediately (during
        // backoff) instead of waiting out the timer.
        vm.retryConnect()
        XCTAssertNil(vm.disconnectedBanner, "retryConnect must clear the banner right away")
        XCTAssertEqual(factory.made.count, 2, "retry must open a fresh task immediately")
        let secondTask = try XCTUnwrap(factory.latest)
        XCTAssertFalse(secondTask === firstTask, "retry must open a fresh task immediately")
        secondTask.completeHandshake(error: URLError(.networkConnectionLost))
        await settle()

        XCTAssertEqual(vm.socket.state, .reconnecting(attempt: 2))
        XCTAssertNotNil(vm.disconnectedBanner, "banner must return on the second reconnecting transition too")
    }
}
