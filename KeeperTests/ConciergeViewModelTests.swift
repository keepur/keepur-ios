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
        makeViewModel()

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

    /// (Re)build `vm` on a socket with the given token-read config; `setUp` uses the defaults.
    private func makeViewModel(tokenReadRetryDelay: Duration = .seconds(2), maxTokenReadRetries: Int = 3) {
        var config = BeekeeperSocket.Config.standard
        config.tokenReadRetryDelay = tokenReadRetryDelay
        config.maxTokenReadRetries = maxTokenReadRetries
        let factory = self.factory!
        let socket = BeekeeperSocket(
            config: config,
            credentials: credentials,
            endpoint: { URL(string: "wss://unit.test")! },
            taskFactory: { factory.make(url: $0) }   // closure literal, not `factory.make`
        )
        vm = ChatViewModel(socket: socket, credentials: credentials)
    }

    private func waitUntil(timeoutMs: Int, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Test 19's setup: a configured-but-unpaired VM whose flow has bailed offline.
    private func bailOffline() async throws -> (store: ConciergeSessionStore, concierge: ConciergeViewModel) {
        makeViewModel(tokenReadRetryDelay: .milliseconds(1), maxTokenReadRetries: 1)
        credentials.token = nil
        let store = ConciergeSessionStore(defaults: defaults)
        store.cache(sessionId: "cached-session", path: "/cached/path")

        vm.configure(context: context)   // configured, so the bail comes from state, not from ordering
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.connectionState, .disconnected)

        let concierge = ConciergeViewModel()
        concierge.start(viewModel: vm, store: store)
        try await waitUntil(timeoutMs: 500) {
            if case .error = concierge.state { return true }
            return false
        }
        return (store, concierge)
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
        XCTAssertEqual(vm.connectionState, .connected)

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

    /// 19: offline cold start bails at once — no sends, no dead timeouts, cache kept.
    func testRunFlowBailsWithoutClearingCacheWhenDisconnected() async throws {
        let (store, concierge) = try await bailOffline()

        XCTAssertEqual(concierge.state, .error("Not connected. Retry when reconnected."))
        XCTAssertTrue(concierge.bailedOffline)
        XCTAssertNotNil(store.cachedSession, "an offline bail must not wipe the cached concierge id")
        XCTAssertEqual(factory.made.count, 0, "nothing was opened or sent")
    }

    /// 19a (⚠9): the next `.connected` re-runs the flow once via the view's `.onChange` hook.
    func testBailedFlowRerunsOnConnected() async throws {
        let (store, concierge) = try await bailOffline()

        credentials.token = "test-token"
        vm.reconnect()
        let task = try XCTUnwrap(factory.latest)
        task.completeHandshake()
        await settle()
        XCTAssertEqual(vm.connectionState, .connected)

        concierge.retryIfBailedOffline(viewModel: vm, store: store)   // what BeekeeperRootView's .onChange calls
        try await waitUntil(timeoutMs: 500) { (try? self.sentTypes(task))?.contains("resume_session") == true }

        XCTAssertFalse(concierge.bailedOffline)
        XCTAssertEqual(try sentTypes(task), ["ping", "list_sessions", "resume_session"],
                       "the flow re-ran from the top with the cache hit")
        XCTAssertNotNil(store.cachedSession)

        task.deliver(#"{"type":"session_info","sessionId":"cached-session","path":"/cached/path","mode":"concierge"}"#)
        try await waitUntil(timeoutMs: 500) { concierge.state == .ready(sessionId: "cached-session", path: "/cached/path") }
        XCTAssertEqual(concierge.state, .ready(sessionId: "cached-session", path: "/cached/path"))

        concierge.retryIfBailedOffline(viewModel: vm, store: store)   // not bailed: must be a no-op
        XCTAssertEqual(concierge.state, .ready(sessionId: "cached-session", path: "/cached/path"))
    }
}
