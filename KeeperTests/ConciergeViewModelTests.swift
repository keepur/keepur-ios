import XCTest
import SwiftData
@testable import Keepur

/// `ConciergeViewModel.runFlow` on an injected `BeekeeperSocket` driven by the
/// fake task. Pins the cold-start fix: `runFlow` must wait for the handshake
/// before its first send, or a cache-hit `resume_session` is silently dropped
/// (`BeekeeperSocket.send` returns `false` while not `.connected`) and the flow
/// falls through to the list/spawn fallbacks instead of resuming the cached slot.
@MainActor
final class ConciergeViewModelTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var credentials: FakeCredentialStore!
    private var factory: FakeWebSocketTaskFactory!
    private var vm: ChatViewModel!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Session.self, Message.self, configurations: config)
        context = ModelContext(container)
        credentials = FakeCredentialStore()
        factory = FakeWebSocketTaskFactory()
        let factory = self.factory!
        let socket = BeekeeperSocket(
            config: .standard,
            credentials: credentials,
            endpoint: { URL(string: "wss://unit.test")! },
            taskFactory: { factory.make(url: $0) }   // closure literal, not `factory.make`
        )
        vm = ChatViewModel(socket: socket, credentials: credentials)

        // Seed the concierge cache in an isolated UserDefaults suite so this test
        // never touches the real `.standard` defaults.
        suiteName = "ConciergeViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        vm = nil
        factory = nil
        credentials = nil
        context = nil
        container = nil
    }

    // MARK: - Helpers

    /// Let the socket's `Task { @MainActor in … }` hops run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// The `type` field of each frame the fake task was asked to send, in order.
    private func sentTypes(_ task: FakeWebSocketTask) throws -> [String] {
        try task.sentTexts.map { text in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            return try XCTUnwrap(json["type"] as? String)
        }
    }

    // MARK: - Tests

    func testRunFlowWaitsForHandshakeBeforeCacheHitResume() async throws {
        let store = ConciergeSessionStore(defaults: defaults)
        store.cache(sessionId: "cached-session", path: "/cached/path")

        // Cold start: `configure()` kicks off `connect()` but the handshake hasn't
        // completed yet — mirrors the real race between the tab's `.task` and the
        // socket's async ping round-trip.
        vm.configure(context: context)
        let task = try XCTUnwrap(factory.latest)
        XCTAssertTrue(task.sentTexts.isEmpty, "nothing sent before the handshake completes")

        let concierge = ConciergeViewModel()
        concierge.start(viewModel: vm, store: store)

        // `runFlow` is now polling for the connection every 50ms. Give it a couple
        // of polls' worth of head start while still disconnected, and confirm the
        // cache-hit resume_session has NOT gone out yet (i.e. it isn't dropped by
        // sending too early).
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(task.sentTexts.isEmpty, "resume_session must not be sent before the socket is connected")

        task.completeHandshake()
        await settle()
        XCTAssertTrue(vm.socket.isConnected)

        // Let the poll loop notice the now-connected socket and send resume_session.
        try await Task.sleep(for: .milliseconds(150))
        await settle()

        let types = try sentTypes(task)
        XCTAssertEqual(
            types,
            ["ping", "list_sessions", "resume_session"],
            "keep-alive, then ChatViewModel's onConnected list_sessions, then the cache-hit resume_session — not dropped by the pre-connect race"
        )
    }
}
