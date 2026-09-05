import XCTest
import Combine
@testable import Keepur

@MainActor
final class BeekeeperSocketTests: XCTestCase {
    private var factory: FakeWebSocketTaskFactory!
    private var credentials: FakeCredentialStore!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() async throws {
        factory = FakeWebSocketTaskFactory()
        credentials = FakeCredentialStore()
        cancellables = []
    }

    override func tearDown() async throws {
        cancellables = nil
        credentials = nil
        factory = nil
    }

    // MARK: - Helpers

    private func makeSocket(
        pingInterval: Duration = .seconds(30),
        tokenReadRetryDelay: Duration = .seconds(2),
        maxTokenReadRetries: Int = 3
    ) -> BeekeeperSocket {
        var config = BeekeeperSocket.Config.standard
        config.pingInterval = pingInterval
        config.tokenReadRetryDelay = tokenReadRetryDelay
        config.maxTokenReadRetries = maxTokenReadRetries
        let factory = self.factory!
        return BeekeeperSocket(
            config: config,
            credentials: credentials,
            endpoint: { URL(string: "wss://unit.test")! },
            taskFactory: { factory.make(url: $0) }   // closure literal, not `factory.make`
        )
    }

    /// Let the socket's `Task { @MainActor in … }` hops run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private func connectAndHandshake(_ socket: BeekeeperSocket, channel: String = "beekeeper") async -> FakeWebSocketTask {
        socket.connect(channel: channel)
        let task = try! XCTUnwrap(factory.latest)
        task.completeHandshake()
        await settle()
        return task
    }

    // MARK: - Tests

    func testHandshakeSuccessReachesConnectedAndFiresOnConnected() async throws {
        let socket = makeSocket()
        var connectedCalls = 0
        socket.onConnected = { connectedCalls += 1 }

        socket.connect(channel: "beekeeper")
        XCTAssertEqual(socket.state, .connecting)
        let task = try XCTUnwrap(factory.latest)
        XCTAssertTrue(task.resumed)
        XCTAssertTrue(task.handshakeRequested)
        XCTAssertTrue(task.url.absoluteString.hasSuffix("?token=test-token&channel=beekeeper"))
        XCTAssertFalse(socket.isConnected)

        task.completeHandshake()
        await settle()

        XCTAssertEqual(socket.state, .connected)
        XCTAssertEqual(connectedCalls, 1)
        XCTAssertEqual(task.sentTexts, [#"{"type":"ping"}"#], "keep-alive sent once right after the handshake")
    }

    func testHandshakeFailureSchedulesReconnectAttemptOne() async throws {
        let socket = makeSocket()
        socket.connect(channel: "beekeeper")
        let task = try XCTUnwrap(factory.latest)

        task.completeHandshake(error: URLError(.cannotConnectToHost))
        await settle()

        XCTAssertEqual(socket.state, .reconnecting(attempt: 1))
        XCTAssertTrue(task.cancelled)
        XCTAssertEqual(factory.made.count, 1, "backoff is 2 s; no second task yet")
    }

    func testCloseCode4001FiresAuthFailureAndDoesNotReconnect() async throws {
        let socket = makeSocket()
        var authFailures = 0
        socket.onAuthFailure = { authFailures += 1 }
        let task = await connectAndHandshake(socket)

        task.failReceive(closeCode: URLSessionWebSocketTask.CloseCode(rawValue: 4001)!)
        await settle()

        XCTAssertEqual(authFailures, 1)
        XCTAssertEqual(socket.state, .disconnected)
        XCTAssertEqual(factory.made.count, 1)
    }

    func testSendReturnsFalseWhileNotConnected() async throws {
        let socket = makeSocket()
        XCTAssertFalse(socket.send(Data("{}".utf8)))

        socket.connect(channel: "beekeeper")
        XCTAssertFalse(socket.send(Data("{}".utf8)), "still handshaking")

        let task = try XCTUnwrap(factory.latest)
        task.completeHandshake()
        await settle()
        XCTAssertTrue(socket.send(Data(#"{"type":"list_sessions"}"#.utf8)))
        XCTAssertEqual(task.sentTexts.last, #"{"type":"list_sessions"}"#)
    }

    func testFramesAreMulticastToEverySubscriber() async throws {
        let socket = makeSocket()
        var first: [String] = []
        var second: [String] = []
        socket.frames.sink { first.append(String(decoding: $0, as: UTF8.self)) }.store(in: &cancellables)
        socket.frames.sink { second.append(String(decoding: $0, as: UTF8.self)) }.store(in: &cancellables)
        let task = await connectAndHandshake(socket)

        task.deliver(#"{"type":"pong"}"#)
        await settle()

        XCTAssertEqual(first, [#"{"type":"pong"}"#])
        XCTAssertEqual(second, [#"{"type":"pong"}"#])
    }

    func testConnectToDifferentChannelTearsDownAndReconnects() async throws {
        let socket = makeSocket()
        let old = await connectAndHandshake(socket, channel: "hive-a")

        socket.connect(channel: "hive-b")

        XCTAssertTrue(old.cancelled)
        XCTAssertEqual(factory.made.count, 2)
        XCTAssertTrue(try XCTUnwrap(factory.latest).url.absoluteString.hasSuffix("&channel=hive-b"))
        XCTAssertEqual(socket.state, .connecting)
        XCTAssertEqual(socket.lastChannel, "hive-b")
    }

    func testConnectSameChannelWhileConnectedIsNoOp() async throws {
        let socket = makeSocket()
        let task = await connectAndHandshake(socket)

        socket.connect(channel: "beekeeper")

        XCTAssertFalse(task.cancelled)
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertEqual(socket.state, .connected)
    }

    func testConnectSameChannelDuringBackoffAttemptsImmediately() async throws {
        let socket = makeSocket()
        socket.connect(channel: "beekeeper")
        try XCTUnwrap(factory.latest).completeHandshake(error: URLError(.cannotConnectToHost))
        await settle()
        XCTAssertEqual(socket.state, .reconnecting(attempt: 1))

        socket.connect(channel: "beekeeper")   // what foregrounding does via reconnect()

        XCTAssertEqual(factory.made.count, 2, "no 2 s wait")
        XCTAssertEqual(socket.state, .reconnecting(attempt: 1), "attempt count is kept while the retry is in flight")
        try XCTUnwrap(factory.latest).completeHandshake()
        await settle()
        XCTAssertEqual(socket.state, .connected)
    }

    func testPingLoopStopsAfterDisconnect() async throws {
        let socket = makeSocket(pingInterval: .milliseconds(20))
        let task = await connectAndHandshake(socket)

        try await Task.sleep(for: .milliseconds(200))
        let sentWhileConnected = task.sentTexts.count
        XCTAssertGreaterThanOrEqual(sentWhileConnected, 3, "handshake keep-alive plus at least two loop pings")

        socket.disconnect()
        XCTAssertEqual(socket.state, .disconnected)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(task.sentTexts.count, sentWhileConnected, "no pings after disconnect")
    }

    func testMissingTokenRetriesThenGivesUp() async throws {
        credentials.token = nil
        let socket = makeSocket(tokenReadRetryDelay: .milliseconds(10), maxTokenReadRetries: 2)

        socket.connect(channel: "beekeeper")
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(factory.made.count, 0, "never opened a task without a token")
        XCTAssertEqual(socket.state, .disconnected, "not paired, so no backoff either")
    }

    /// `Config.standard.keepAliveFrame` is a hardcoded bare `{"type":"ping"}` because
    /// both wire protocols happen to encode their `.ping` case identically. Pin that
    /// coupling so a future change to either encoder's ping shape fails loudly here
    /// instead of silently breaking keep-alive on one channel.
    func testStandardKeepAliveFrameMatchesBothPingEncoders() throws {
        let keepAliveFrame = BeekeeperSocket.Config.standard.keepAliveFrame
        XCTAssertEqual(keepAliveFrame, try WSOutgoing.ping.encode())
        XCTAssertEqual(keepAliveFrame, try TeamWSOutgoing.ping.encode())
    }
}
