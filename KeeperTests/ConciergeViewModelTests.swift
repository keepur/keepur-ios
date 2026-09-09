import XCTest
import SwiftData
import Combine
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
    private var concierges: [ConciergeViewModel] = []

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Session.self, Message.self, Workspace.self, configurations: config)
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
        vm?.unpair()
        concierges.removeAll()
        await settle()
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

    private func makeConcierge() -> ConciergeViewModel {
        let concierge = ConciergeViewModel()
        concierges.append(concierge)
        return concierge
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

        let concierge = makeConcierge()
        concierge.start(viewModel: vm, store: store)
        try await eventually("concierge reports offline", timeout: .milliseconds(500)) {
            if case .error = concierge.state { return true }
            return false
        }
        return (store, concierge)
    }

    private func assertStageReleased(
        _ probe: ConciergeFlowProbe,
        runRemainsActive: Bool = true,
        timeout: Duration = .seconds(1)
    ) async throws {
        try await eventually("request-local latch and subscription released", timeout: timeout) {
            probe.latch.value == nil && probe.subscription.value == nil
        }
        if runRemainsActive {
            XCTAssertNotNil(probe.run.value)
        }
    }

    private func assertFlowFinished(
        _ probe: ConciergeFlowProbe,
        timeout: TimeInterval = 1
    ) async throws {
        let completed = expectation(description: "captured concierge flow task finishes")
        let observer = Task { @MainActor in
            await probe.task.value
            completed.fulfill()
        }
        defer { observer.cancel() }
        await fulfillment(of: [completed], timeout: timeout)
        try await eventually("flow-owned references released", timeout: .seconds(timeout)) {
            probe.run.value == nil && probe.latch.value == nil && probe.subscription.value == nil
        }
    }

    private func reflectedFlowTask(_ coordinator: ConciergeViewModel) throws -> Task<Void, Never> {
        let field = try XCTUnwrap(
            Mirror(reflecting: coordinator).children.first { $0.label == "flowTask" }?.value
        )
        let stored = try XCTUnwrap(field as? Optional<Task<Void, Never>>)
        return try XCTUnwrap(stored)
    }

    private func assertPrivateFlowCleared(_ coordinator: ConciergeViewModel) throws {
        for name in ["activeRun", "flowTask"] {
            let field = try XCTUnwrap(
                Mirror(reflecting: coordinator).children.first { $0.label == name }?.value
            )
            let mirror = Mirror(reflecting: field)
            XCTAssertEqual(mirror.displayStyle, .optional, "\(name) must remain optional storage")
            XCTAssertTrue(mirror.children.isEmpty, "\(name) must be nil after the flow exits")
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

        let concierge = makeConcierge()
        concierge.start(viewModel: vm, store: store)

        // Give the flow a head start while still disconnected, and confirm the
        // cache-hit resume_session has NOT gone out yet (i.e. it isn't dropped by
        // sending too early).
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(task.sentTexts.isEmpty, "resume_session must not be sent before the socket is connected")

        task.completeHandshake()
        await settle()
        XCTAssertEqual(vm.connectionState, .connected)

        try await eventually("cache-hit resume sent", timeout: .milliseconds(500)) {
            (try? self.sentTypes(task))?.contains("resume_session") == true
        }

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
        try await eventually("retry sends cached resume", timeout: .milliseconds(500)) {
            (try? self.sentTypes(task))?.contains("resume_session") == true
        }

        XCTAssertFalse(concierge.bailedOffline)
        XCTAssertEqual(try sentTypes(task), ["ping", "list_sessions", "resume_session"],
                       "the flow re-ran from the top with the cache hit")
        XCTAssertNotNil(store.cachedSession)

        task.deliver(#"{"type":"session_info","sessionId":"cached-session","path":"/cached/path","mode":"concierge"}"#)
        try await eventually("cached concierge becomes ready", timeout: .milliseconds(500)) {
            concierge.state == .ready(sessionId: "cached-session", path: "/cached/path")
        }
        XCTAssertEqual(concierge.state, .ready(sessionId: "cached-session", path: "/cached/path"))

        concierge.retryIfBailedOffline(viewModel: vm, store: store)   // not bailed: must be a no-op
        XCTAssertEqual(concierge.state, .ready(sessionId: "cached-session", path: "/cached/path"))
    }

    func testDroppingCoordinatorDuringSuspendedReplyCancelsOwnedWork() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        h.store.cache(sessionId: "cached", path: "/cached")
        var coordinator: ConciergeViewModel? = ConciergeViewModel()
        weak var weakCoordinator = coordinator
        coordinator?.start(viewModel: h.vm, store: h.store)
        try await eventually("resume sent with suspended reply wait") {
            try h.frames("resume_session").count == 1
        }
        let probe = try ConciergeFlowProbe(XCTUnwrap(coordinator))
        XCTAssertNotNil(probe.run.value)
        XCTAssertNotNil(probe.latch.value)
        XCTAssertNotNil(probe.subscription.value)
        let completed = expectation(description: "canceled flow actually finishes")
        let observer = Task { @MainActor in await probe.task.value; completed.fulfill() }
        defer { observer.cancel() }
        coordinator = nil
        XCTAssertNil(weakCoordinator, "the flow must not retain its owning coordinator")
        await fulfillment(of: [completed], timeout: 1)
        try await eventually("request-local objects released") {
            probe.run.value == nil && probe.latch.value == nil && probe.subscription.value == nil
        }
        let count = try h.frames().count
        try await h.receive([
            "type": "session_info", "sessionId": "cached", "path": "/late", "mode": "concierge"
        ])
        XCTAssertEqual(h.store.cachedSession?.path, "/cached")
        XCTAssertEqual(try h.frames().count, count, "late reply cannot send a fallback")
    }

    func testSynchronousDecodedReplyInsideSendIsBufferedAndFirstOnly() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        h.store.cache(sessionId: "cached", path: "/cached")
        let coordinator = ConciergeViewModel()
        var invoked = false
        var probe: ConciergeFlowProbe?
        h.task.onSend = { text in
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  object["type"] as? String == "resume_session" else { return }
            invoked = true
            do {
                probe = try ConciergeFlowProbe(coordinator)
            } catch {
                XCTFail("Failed to capture synchronous flow probe: \(error)")
            }
            h.vm.incoming.send(.sessionInfo(sessionId: "other", path: "/other", mode: .sessions))
            h.vm.incoming.send(.sessionInfo(sessionId: "cached", path: "/first", mode: .sessions))
            h.vm.incoming.send(.sessionInfo(sessionId: "cached", path: "/second", mode: .concierge))
        }
        coordinator.start(viewModel: h.vm, store: h.store)
        try await eventually("synchronous reply consumed") {
            coordinator.state == .ready(sessionId: "cached", path: "/first")
        }
        XCTAssertTrue(invoked)
        XCTAssertEqual(h.store.cachedSession?.path, "/first")
        XCTAssertEqual(try h.frames("resume_session").count, 1)
        XCTAssertTrue(try h.frames("new_session").isEmpty)
        try await assertFlowFinished(try XCTUnwrap(probe))
    }

    func testCachedLegacyResumeUpdatesCacheWithoutSessionOrWorkspaceRows() async throws {
        let standardId = UserDefaults.standard.string(forKey: ConciergeSessionStore.sessionIdKey)
        let standardPath = UserDefaults.standard.string(forKey: ConciergeSessionStore.pathKey)
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        h.store.cache(sessionId: "C", path: "/old")
        let coordinator = ConciergeViewModel()
        var observedPostHandler = false
        let observation = h.vm.incoming.sink { frame in
            guard case .sessionInfo(let id, _, _) = frame, id == "C" else { return }
            observedPostHandler = true
            XCTAssertEqual(h.vm.currentSessionId, "C")
            XCTAssertEqual(h.vm.currentPath, "/actual")
            XCTAssertTrue((try? h.sessions().isEmpty) == true)
            XCTAssertTrue((try? h.workspaces().isEmpty) == true)
            XCTAssertEqual(coordinator.state, .loading)
        }
        defer { observation.cancel() }
        coordinator.start(viewModel: h.vm, store: h.store)
        try await eventually("cached legacy resume sent") { try h.frames("resume_session").count == 1 }
        XCTAssertEqual(try h.frames("resume_session").first as NSDictionary?, [
            "type": "resume_session", "sessionId": "C", "path": "/old"
        ] as NSDictionary)
        let probe = try ConciergeFlowProbe(coordinator)
        try await h.receive(["type": "session_info", "sessionId": "C", "path": "/actual"])
        try await eventually("legacy resume becomes ready") {
            coordinator.state == .ready(sessionId: "C", path: "/actual")
        }
        XCTAssertTrue(observedPostHandler)
        XCTAssertEqual(h.store.cachedSession?.sessionId, "C")
        XCTAssertEqual(h.store.cachedSession?.path, "/actual")
        XCTAssertTrue(try h.frames("new_session").isEmpty)
        XCTAssertEqual(UserDefaults.standard.string(forKey: ConciergeSessionStore.sessionIdKey), standardId)
        XCTAssertEqual(UserDefaults.standard.string(forKey: ConciergeSessionStore.pathKey), standardPath)
        try await assertFlowFinished(probe)
    }

    func testDiscoveryRegistersIdentityBeforeLegacyResumeHandler() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        let coordinator = ConciergeViewModel()
        let initialLists = try h.frames("list_sessions").count
        var observedPostHandler = false
        let observation = h.vm.incoming.sink { frame in
            guard case .sessionInfo(let id, _, _) = frame, id == "C" else { return }
            observedPostHandler = true
            XCTAssertEqual(h.vm.currentSessionId, "C")
            XCTAssertEqual(h.vm.currentPath, "/actual")
            XCTAssertFalse((try? h.sessions().contains { $0.id == "C" }) == true)
            XCTAssertFalse((try? h.workspaces().contains { $0.path == "/actual" }) == true)
            XCTAssertEqual(coordinator.state, .loading)
        }
        defer { observation.cancel() }
        coordinator.start(viewModel: h.vm, store: h.store)
        try await eventually("coordinator sends a fresh discovery list") {
            try h.frames("list_sessions").count == initialLists + 1
        }
        let discoveryProbe = try ConciergeFlowProbe(coordinator)
        try await h.receive([
            "type": "session_list",
            "sessions": [
                ["sessionId": "N", "path": "/normal", "state": "idle", "mode": "sessions"],
                ["sessionId": "C", "path": "/listed", "state": "idle", "mode": "concierge"]
            ]
        ])
        try await eventually("discovered concierge resume sent") { try h.frames("resume_session").count == 1 }
        try await assertStageReleased(discoveryProbe)
        XCTAssertNil(h.store.cachedSession, "discovery must not speculatively write the cache")
        XCTAssertEqual(try h.frames("resume_session").first as NSDictionary?, [
            "type": "resume_session", "sessionId": "C", "path": "/listed"
        ] as NSDictionary)
        let resumeProbe = try ConciergeFlowProbe(coordinator)
        try await h.receive(["type": "session_info", "sessionId": "C", "path": "/actual"])
        try await eventually("discovered legacy concierge becomes ready") {
            coordinator.state == .ready(sessionId: "C", path: "/actual")
        }
        XCTAssertTrue(observedPostHandler)
        XCTAssertEqual(h.store.cachedSession?.sessionId, "C")
        XCTAssertEqual(h.store.cachedSession?.path, "/actual")
        try await assertFlowFinished(resumeProbe)
        try await eventually("discovery run releases after success") { discoveryProbe.run.value == nil }
    }

    func testEmptyFreshListImmediatelySpawnsAndFiltersNormalInfo() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        try await h.list([("old", "idle", "concierge")])
        XCTAssertEqual(h.vm.serverSessions.first?.sessionId, "old")
        let coordinator = ConciergeViewModel()
        let initialLists = try h.frames("list_sessions").count
        coordinator.start(viewModel: h.vm, store: h.store)
        try await eventually("fresh discovery request sent") {
            try h.frames("list_sessions").count == initialLists + 1
        }
        XCTAssertTrue(try h.frames("resume_session").isEmpty, "the old published snapshot is not a reply")
        let discoveryProbe = try ConciergeFlowProbe(coordinator)
        try await h.receive(["type": "session_list", "sessions": []])
        try await eventually("fresh empty list spawns immediately", timeout: .seconds(1)) {
            try h.frames("new_session").count == 1
        }
        try await assertStageReleased(discoveryProbe)
        XCTAssertEqual(try h.frames("new_session").first as NSDictionary?, [
            "type": "new_session", "mode": "concierge"
        ] as NSDictionary)
        let spawnProbe = try ConciergeFlowProbe(coordinator)
        try await h.receive([
            "type": "session_info", "sessionId": "N", "path": "/normal", "mode": "sessions"
        ])
        try await h.receive([
            "type": "session_info", "sessionId": "C", "path": "", "mode": "concierge"
        ])
        XCTAssertEqual(coordinator.state, .loading)
        XCTAssertNil(h.store.cachedSession)
        try await h.receive([
            "type": "session_info", "sessionId": "C", "path": "/actual", "mode": "concierge"
        ])
        try await eventually("fresh concierge becomes ready") {
            coordinator.state == .ready(sessionId: "C", path: "/actual")
        }
        XCTAssertEqual(h.store.cachedSession?.sessionId, "C")
        XCTAssertEqual(h.store.cachedSession?.path, "/actual")
        try await assertFlowFinished(spawnProbe)
    }

    func testRawReplyDeliveredByFakeSendHookSeesHandlerBeforeReady() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        h.store.cache(sessionId: "C", path: "/old")
        let coordinator = ConciergeViewModel()
        var probe: ConciergeFlowProbe?
        var sawPostHandler = false
        let observation = h.vm.incoming.sink { frame in
            guard case .sessionInfo(let id, _, _) = frame, id == "C" else { return }
            sawPostHandler = true
            XCTAssertEqual(h.vm.currentSessionId, "C")
            XCTAssertEqual(h.vm.currentPath, "/hook")
            XCTAssertTrue((try? h.sessions().isEmpty) == true)
            XCTAssertTrue((try? h.workspaces().isEmpty) == true)
            XCTAssertEqual(coordinator.state, .loading)
        }
        defer { observation.cancel() }
        h.task.onSend = { text in
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  object["type"] as? String == "resume_session" else { return }
            do {
                probe = try ConciergeFlowProbe(coordinator)
            } catch {
                XCTFail("Failed to capture raw send-hook flow probe: \(error)")
            }
            h.task.deliver(#"{"type":"session_info","sessionId":"C","path":"/hook"}"#)
        }
        coordinator.start(viewModel: h.vm, store: h.store)
        try await eventually("raw send-hook reply becomes ready") {
            coordinator.state == .ready(sessionId: "C", path: "/hook")
        }
        XCTAssertTrue(sawPostHandler)
        XCTAssertEqual(h.store.cachedSession?.path, "/hook")
        try await assertFlowFinished(try XCTUnwrap(probe))
    }

    func testConnectedCachedResumeTimeoutFallsThroughOnce() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        h.store.cache(sessionId: "C", path: "/old")
        let coordinator = ConciergeViewModel()
        let initialLists = try h.frames("list_sessions").count
        coordinator.start(viewModel: h.vm, store: h.store)
        try await eventually("cached resume sent") { try h.frames("resume_session").count == 1 }
        let oldProbe = try ConciergeFlowProbe(coordinator)
        try await eventually("resume timeout falls through once", timeout: .milliseconds(4500)) {
            try h.frames("list_sessions").count == initialLists + 1
        }
        XCTAssertNil(h.store.cachedSession)
        try await assertStageReleased(oldProbe)
        XCTAssertEqual(try h.frames("list_sessions").count, initialLists + 1)
        let discoveryProbe = try ConciergeFlowProbe(coordinator)
        try await h.list([("D", "idle", "concierge")])
        try await eventually("discovered replacement resumes") { try h.frames("resume_session").count == 2 }
        try await assertStageReleased(discoveryProbe)
        let finalProbe = try ConciergeFlowProbe(coordinator)
        try await h.receive([
            "type": "session_info", "sessionId": "D", "path": "/D", "mode": "concierge"
        ])
        try await eventually("replacement concierge ready") {
            coordinator.state == .ready(sessionId: "D", path: "/D")
        }
        let resumes = try h.frames("resume_session")
        XCTAssertEqual(resumes.compactMap { $0["sessionId"] as? String }, ["C", "D"])
        XCTAssertTrue(try h.frames("new_session").isEmpty)
        try await assertFlowFinished(finalProbe)
        try await eventually("old timeout run releases after success") { oldProbe.run.value == nil }
    }

    func testConnectedDiscoveredResumeTimeoutSpawnsOnce() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        let coordinator = ConciergeViewModel()
        let initialLists = try h.frames("list_sessions").count
        coordinator.start(viewModel: h.vm, store: h.store)
        try await eventually("fresh list requested") { try h.frames("list_sessions").count == initialLists + 1 }
        let discoveryProbe = try ConciergeFlowProbe(coordinator)
        try await h.list([("C", "idle", "concierge")])
        try await eventually("discovered C resumes") { try h.frames("resume_session").count == 1 }
        try await assertStageReleased(discoveryProbe)
        let resumeProbe = try ConciergeFlowProbe(coordinator)
        try await eventually("discovered resume timeout spawns", timeout: .milliseconds(4500)) {
            try h.frames("new_session").count == 1
        }
        try await assertStageReleased(resumeProbe)
        let spawnProbe = try ConciergeFlowProbe(coordinator)
        try await h.receive([
            "type": "session_info", "sessionId": "D", "path": "/D", "mode": "concierge"
        ])
        try await eventually("spawned D becomes ready") {
            coordinator.state == .ready(sessionId: "D", path: "/D")
        }
        try await assertFlowFinished(spawnProbe)
        try await h.receive([
            "type": "session_info", "sessionId": "C", "path": "/late", "mode": "concierge"
        ])
        XCTAssertEqual(coordinator.state, .ready(sessionId: "D", path: "/D"))
        XCTAssertEqual(h.store.cachedSession?.sessionId, "D")
        XCTAssertEqual(try h.frames("new_session").count, 1)
    }

    func testDiscoveryTimeoutAndSpawnTimeoutKeepExistingError() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        let coordinator = ConciergeViewModel()
        let initialLists = try h.frames("list_sessions").count
        coordinator.start(viewModel: h.vm, store: h.store)
        try await eventually("fresh list requested") { try h.frames("list_sessions").count == initialLists + 1 }
        let discoveryProbe = try ConciergeFlowProbe(coordinator)
        try await eventually("discovery timeout spawns once", timeout: .milliseconds(4500)) {
            try h.frames("new_session").count == 1
        }
        try await assertStageReleased(discoveryProbe)
        let spawnProbe = try ConciergeFlowProbe(coordinator)
        try await eventually("spawn timeout keeps existing error", timeout: .milliseconds(6500)) {
            coordinator.state == .error("Concierge did not respond in time")
        }
        XCTAssertEqual(try h.frames("new_session").count, 1)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(try h.frames("new_session").count, 1, "timeout must not retry")
        try await assertFlowFinished(spawnProbe)
        try await eventually("discovery run releases after terminal timeout") { discoveryProbe.run.value == nil }
    }

    func testFreshSpawnIgnoresLegacyModeWithoutKnownIdentity() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        let coordinator = ConciergeViewModel()
        let initialLists = try h.frames("list_sessions").count
        coordinator.start(viewModel: h.vm, store: h.store)
        try await eventually("fresh list requested") { try h.frames("list_sessions").count == initialLists + 1 }
        try await h.receive(["type": "session_list", "sessions": []])
        try await eventually("fresh spawn requested") { try h.frames("new_session").count == 1 }
        let spawnProbe = try ConciergeFlowProbe(coordinator)
        try await h.receive(["type": "session_info", "sessionId": "legacy", "path": "/legacy"])
        try await h.receive(["type": "error", "message": "scoped", "sessionId": "legacy"])
        try await h.receive(["type": "error", "message": "unscoped"])
        XCTAssertEqual(coordinator.state, .loading)
        XCTAssertNil(h.store.cachedSession)
        XCTAssertNotNil(h.vm.lastError, "Chat retains its unscoped error routing")
        try await eventually("uncorrelated spawn times out", timeout: .milliseconds(6500)) {
            coordinator.state == .error("Concierge did not respond in time")
        }
        XCTAssertEqual(try h.frames("new_session").count, 1)
        try await assertFlowFinished(spawnProbe)
    }

    func testRejectedResumeBailsOfflineAndRetainsCache() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        let stateSubscription = try XCTUnwrap(
            Mirror(reflecting: h.vm).children.first { $0.label == "stateSubscription" }?.value
                as? Optional<AnyCancellable>
        )
        try XCTUnwrap(stateSubscription).cancel()
        h.socket.disconnect()
        XCTAssertEqual(h.vm.connectionState, .connected)
        XCTAssertEqual(h.socket.state, .disconnected)
        h.store.cache(sessionId: "C", path: "/cached")
        var coordinator: ConciergeViewModel? = ConciergeViewModel()
        weak var weakCoordinator = coordinator
        coordinator?.start(viewModel: h.vm, store: h.store)
        try await eventually("rejected resume bails offline") {
            coordinator?.state == .error("Not connected. Retry when reconnected.")
        }
        XCTAssertEqual(h.store.cachedSession?.sessionId, "C")
        XCTAssertEqual(h.store.cachedSession?.path, "/cached")
        XCTAssertTrue(try h.frames("resume_session").isEmpty)
        XCTAssertTrue(try h.frames("new_session").isEmpty)
        try assertPrivateFlowCleared(try XCTUnwrap(coordinator))
        coordinator = nil
        XCTAssertNil(weakCoordinator, "a rejected send leaves no suspended owner work")
    }

    func testDisconnectDuringResumeTimeoutKeepsCacheAndDoesNotSpawn() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        h.store.cache(sessionId: "C", path: "/cached")
        let coordinator = ConciergeViewModel()
        let firstTask = h.task
        coordinator.start(viewModel: h.vm, store: h.store)
        try await eventually("cached resume begins") { try h.frames("resume_session").count == 1 }
        let oldProbe = try ConciergeFlowProbe(coordinator)
        let oldListCount = try h.frames("list_sessions").count
        h.socket.disconnect()
        try await eventually("disconnect bails after bounded resume wait", timeout: .milliseconds(4500)) {
            coordinator.state == .error("Not connected. Retry when reconnected.")
        }
        XCTAssertEqual(h.store.cachedSession?.sessionId, "C")
        XCTAssertEqual(firstTask.sentTexts.compactMap { text -> String? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            else { return nil }
            return object["type"] as? String
        }.filter { $0 == "list_sessions" }.count, oldListCount)
        XCTAssertTrue(try h.frames("new_session").isEmpty)
        try await assertFlowFinished(oldProbe)

        h.vm.reconnect()
        try await h.connect()
        let retryTask = h.task
        coordinator.retryIfBailedOffline(viewModel: h.vm, store: h.store)
        coordinator.retryIfBailedOffline(viewModel: h.vm, store: h.store)
        try await eventually("one replacement cached resume sent") {
            retryTask.sentTexts.filter { text in
                (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["type"] as? String
                    == "resume_session"
            }.count == 1
        }
        let retryProbe = try ConciergeFlowProbe(coordinator)
        try await h.receive([
            "type": "session_info", "sessionId": "C", "path": "/actual", "mode": "concierge"
        ])
        try await eventually("replacement run becomes ready") {
            coordinator.state == .ready(sessionId: "C", path: "/actual")
        }
        try await assertFlowFinished(retryProbe)
        let retryCount = retryTask.sentTexts.count
        coordinator.retryIfBailedOffline(viewModel: h.vm, store: h.store)
        await settle()
        XCTAssertEqual(retryTask.sentTexts.count, retryCount)
    }

    func testExplicitRetryDisposesOldWaitAndRejectsOldIdentity() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        h.store.cache(sessionId: "C", path: "/C")
        let coordinator = ConciergeViewModel()
        coordinator.start(viewModel: h.vm, store: h.store)
        try await eventually("C resume sent") { try h.frames("resume_session").count == 1 }
        let oldProbe = try ConciergeFlowProbe(coordinator)
        h.store.cache(sessionId: "D", path: "/D")
        coordinator.retry(viewModel: h.vm, store: h.store)
        try await eventually("D resume sent") { try h.frames("resume_session").count == 2 }
        try await assertFlowFinished(oldProbe)
        let newProbe = try ConciergeFlowProbe(coordinator)
        try await h.receive(["type": "session_info", "sessionId": "C", "path": "/late"])
        XCTAssertEqual(coordinator.state, .loading)
        XCTAssertEqual(h.store.cachedSession?.sessionId, "D")
        try await h.receive(["type": "session_info", "sessionId": "D", "path": "/actual"])
        try await eventually("D legacy reply wins") {
            coordinator.state == .ready(sessionId: "D", path: "/actual")
        }
        XCTAssertFalse(try h.sessions().contains { $0.id == "D" })
        XCTAssertFalse(try h.workspaces().contains { $0.path == "/actual" })
        XCTAssertEqual(try h.frames("resume_session").compactMap { $0["sessionId"] as? String }, ["C", "D"])
        XCTAssertTrue(try h.frames("new_session").isEmpty)
        try await assertFlowFinished(newProbe)
        let listCount = try h.frames("list_sessions").count
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertEqual(try h.frames("list_sessions").count, listCount, "the canceled C wait cannot fall back")
    }

    func testAuthLossThenRepairCannotReviveOldRun() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        h.store.cache(sessionId: "C", path: "/C")
        let coordinator = ConciergeViewModel()
        coordinator.start(viewModel: h.vm, store: h.store)
        try await eventually("C resume sent") { try h.frames("resume_session").count == 1 }
        let oldProbe = try ConciergeFlowProbe(coordinator)
        h.vm.unpair()
        try await assertFlowFinished(oldProbe)
        h.credentials.token = "repaired-token"
        h.credentials.deviceId = "repaired-device"
        h.credentials.deviceName = "Repaired Device"
        h.vm.isAuthenticated = true
        h.store.cache(sessionId: "D", path: "/D")
        h.vm.configure(context: h.context)
        try await h.connect()
        coordinator.retry(viewModel: h.vm, store: h.store)
        try await eventually("fresh D resume sent") { try h.frames("resume_session").count == 1 }
        let freshProbe = try ConciergeFlowProbe(coordinator)
        try await h.receive(["type": "session_info", "sessionId": "D", "path": "/actual"])
        try await eventually("fresh D run becomes ready") {
            coordinator.state == .ready(sessionId: "D", path: "/actual")
        }
        try await assertFlowFinished(freshProbe)
        try await h.receive([
            "type": "session_info", "sessionId": "C", "path": "/late", "mode": "concierge"
        ])
        XCTAssertEqual(coordinator.state, .ready(sessionId: "D", path: "/actual"))
        XCTAssertEqual(h.store.cachedSession?.sessionId, "D")
        XCTAssertEqual(h.store.cachedSession?.path, "/actual")
        XCTAssertTrue(try h.frames("new_session").isEmpty)
    }

    func testStartBeforeConfigureWaitsThroughColdDisconnected() async throws {
        let h = try ChatTestHarness(configure: false); defer { h.close() }
        h.store.cache(sessionId: "C", path: "/C")
        let coordinator = ConciergeViewModel()
        coordinator.start(viewModel: h.vm, store: h.store)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(coordinator.state, .loading)
        XCTAssertNil(h.factory.latest)
        h.vm.configure(context: h.context)
        try await h.connect()
        try await eventually("cold start resumes once configured") { try h.frames("resume_session").count == 1 }
        let probe = try ConciergeFlowProbe(coordinator)
        try await h.receive([
            "type": "session_info", "sessionId": "C", "path": "/actual", "mode": "concierge"
        ])
        try await eventually("cold-start flow becomes ready") {
            coordinator.state == .ready(sessionId: "C", path: "/actual")
        }
        try await assertFlowFinished(probe)
    }

    func testConnectionTimeoutBailsAndPreservesCache() async throws {
        let h = try ChatTestHarness(); defer { h.close() }
        h.store.cache(sessionId: "C", path: "/C")
        var coordinator: ConciergeViewModel? = ConciergeViewModel()
        weak var weakCoordinator = coordinator
        coordinator?.start(viewModel: h.vm, store: h.store)
        let task = try reflectedFlowTask(try XCTUnwrap(coordinator))
        let completed = expectation(description: "connection-timeout flow finishes")
        let observer = Task { @MainActor in await task.value; completed.fulfill() }
        defer { observer.cancel() }
        try await eventually("connection timeout bails", timeout: .milliseconds(6500)) {
            coordinator?.state == .error("Not connected. Retry when reconnected.")
        }
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(h.store.cachedSession?.sessionId, "C")
        XCTAssertEqual(h.store.cachedSession?.path, "/C")
        XCTAssertTrue(h.task.sentTexts.isEmpty)
        try assertPrivateFlowCleared(try XCTUnwrap(coordinator))
        coordinator = nil
        XCTAssertNil(weakCoordinator)
    }
}
